param()

$ErrorActionPreference = 'Stop'

$script:DataRoot = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher'
$script:ProfilesRoot = Join-Path $script:DataRoot 'profiles'
$script:StatePath = Join-Path $script:DataRoot 'profiles.json'
$script:AuthEnvironmentVariables = @(
    'CODEX_HOME',
    'CODEX_ACCESS_TOKEN',
    'OPENAI_API_KEY',
    'OPENAI_IDENTITY_TOKEN_FILE',
    'OPENAI_FEDERATION_RULE_ID'
)
$script:CodexApplication = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

function Get-CodexPath {
    if ($null -eq $script:CodexApplication) {
        throw 'Codex CLI was not found on PATH. Install Codex CLI, open a new PowerShell window, and try again.'
    }

    return $script:CodexApplication.Source
}

function Save-State {
    param([Parameter(Mandatory = $true)]$State)

    if (-not (Test-Path -LiteralPath $script:DataRoot)) {
        New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    }

    $json = ConvertTo-Json -InputObject $State -Depth 10
    $temporaryPath = Join-Path $script:DataRoot ("profiles.{0}.tmp" -f [Guid]::NewGuid().ToString('N'))
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8WithoutBom)
    Move-Item -LiteralPath $temporaryPath -Destination $script:StatePath -Force
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:DataRoot)) {
        New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:ProfilesRoot)) {
        New-Item -ItemType Directory -Path $script:ProfilesRoot -Force | Out-Null
    }

    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
            if ($null -ne $state.profiles) {
                return $state
            }
        }
        catch {
            Write-Warning "The account list could not be read. A backup is saved as profiles.json.broken. Details: $($_.Exception.Message)"
            Copy-Item -LiteralPath $script:StatePath -Destination (Join-Path $script:DataRoot 'profiles.json.broken') -Force
        }
    }

    $defaultHome = $env:CODEX_HOME
    if ([string]::IsNullOrWhiteSpace($defaultHome)) {
        $defaultHome = Join-Path $env:USERPROFILE '.codex'
    }
    $state = [pscustomobject]@{
        version  = 1
        profiles = @(
            [pscustomobject]@{
                id       = 'default'
                label    = 'Default Codex account'
                home     = $defaultHome
                managed  = $false
            }
        )
    }
    Save-State -State $state
    return $state
}

function Send-AppServerMessage {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)]$Message
    )

    $line = ConvertTo-Json -InputObject $Message -Depth 20 -Compress
    $Process.StandardInput.WriteLine($line)
    $Process.StandardInput.Flush()
}

function Read-AppServerResponse {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$ExpectedId,
        [int]$TimeoutMilliseconds = 9000
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $remaining = [Math]::Max(1, $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds)
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw 'Timed out waiting for Codex App Server.'
        }

        $line = $readTask.Result
        if ($null -eq $line) {
            throw 'Codex App Server closed its output before returning a response.'
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $message = $line | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ([string]$message.id -eq $ExpectedId) {
            if ($null -ne $message.error) {
                $errorText = $message.error.message
                if ([string]::IsNullOrWhiteSpace($errorText)) {
                    $errorText = ConvertTo-Json -InputObject $message.error -Compress -Depth 5
                }
                throw "Codex App Server returned an error: $errorText"
            }
            return $message.result
        }
    }

    throw 'Timed out waiting for Codex App Server.'
}

function Invoke-AppServerRequest {
    param(
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$Method,
        [string]$ParametersJson = '{}'
    )

    $codexPath = Get-CodexPath
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $codexExtension = [System.IO.Path]::GetExtension($codexPath)
    if ($codexExtension -in @('.cmd', '.bat')) {
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /s /c ""{0}" app-server"' -f $codexPath
    }
    else {
        $startInfo.FileName = $codexPath
        $startInfo.Arguments = 'app-server'
    }
    if (Test-Path -LiteralPath $CodexHome) {
        $startInfo.WorkingDirectory = $CodexHome
    }
    else {
        $startInfo.WorkingDirectory = $script:DataRoot
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $false
    foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
        [void]$startInfo.EnvironmentVariables.Remove($environmentVariable)
    }
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    $started = $false
    try {
        if (-not $process.Start()) {
            throw 'Could not start Codex App Server.'
        }
        $started = $true

        Send-AppServerMessage -Process $process -Message ([ordered]@{
            method = 'initialize'
            id     = 1
            params = @{
                clientInfo = @{
                    name    = 'codex_account_switcher'
                    title   = 'Codex Account Switcher'
                    version = '1.0.0'
                }
            }
        })
        [void](Read-AppServerResponse -Process $process -ExpectedId '1')
        Send-AppServerMessage -Process $process -Message @{ method = 'initialized'; params = @{} }

        $parameters = $ParametersJson | ConvertFrom-Json
        Send-AppServerMessage -Process $process -Message ([ordered]@{
            method = $Method
            id     = 2
            params = $parameters
        })
        return Read-AppServerResponse -Process $process -ExpectedId '2'
    }
    finally {
        if ($started -and -not $process.HasExited) {
            try { $process.StandardInput.Close() } catch {}
            if (-not $process.WaitForExit(1200)) {
                try { $process.Kill() } catch {}
            }
        }
        $process.Dispose()
    }
}

function Get-ProfileSnapshot {
    param([Parameter(Mandatory = $true)]$AccountProfile)

    $snapshot = [pscustomobject]@{
        profile     = $AccountProfile
        account     = $null
        rateLimits  = $null
        signedIn    = $false
        usageError  = $null
        accountError = $null
    }

    try {
        $accountResult = Invoke-AppServerRequest -CodexHome $AccountProfile.home -Method 'account/read' -ParametersJson '{"refreshToken":false}'
        $snapshot.account = $accountResult.account
        $snapshot.signedIn = ($null -ne $accountResult.account)
        if ($snapshot.signedIn) {
            try {
                $limitResult = Invoke-AppServerRequest -CodexHome $AccountProfile.home -Method 'account/rateLimits/read'
                $snapshot.rateLimits = $limitResult
            }
            catch {
                $snapshot.usageError = $_.Exception.Message
            }
        }
    }
    catch {
        $snapshot.accountError = $_.Exception.Message
    }

    return $snapshot
}

function Get-WindowLabel {
    param([int]$DurationMinutes)

    if ($DurationMinutes -eq 10080) { return 'weekly' }
    if ($DurationMinutes -eq 1440) { return 'daily' }
    if ($DurationMinutes -eq 60) { return 'hourly' }
    if ($DurationMinutes -gt 0 -and ($DurationMinutes % 60) -eq 0) {
        return "every $([int]($DurationMinutes / 60)) hours"
    }
    if ($DurationMinutes -gt 0) { return "every $DurationMinutes minutes" }
    return 'window'
}

function Get-ResetLabel {
    param($Window)

    if ($null -eq $Window.resetsAt) { return 'reset time unavailable' }
    try {
        $resetTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$Window.resetsAt).ToLocalTime()
        return "resets $($resetTime.ToString('ddd HH:mm'))"
    }
    catch {
        return 'reset time unavailable'
    }
}

function Write-UsageBar {
    param(
        [string]$Label,
        [double]$UsedPercent,
        [string]$ResetLabel
    )

    $used = [Math]::Max(0, [Math]::Min(100, $UsedPercent))
    $remaining = 100 - $used
    $width = 18
    $filled = [int][Math]::Round(($used / 100) * $width, 0, [MidpointRounding]::AwayFromZero)
    $bar = ('#' * $filled) + ('-' * ($width - $filled))
    $color = 'Green'
    if ($used -ge 80) { $color = 'Red' }
    elseif ($used -ge 50) { $color = 'Yellow' }

    Write-Host ('    {0,-15} [{1}] {2,3}% used / {3,3}% left; {4}' -f $Label, $bar, [int][Math]::Round($used), [int][Math]::Round($remaining), $ResetLabel) -ForegroundColor $color
}

function Write-ProfileSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)

    $accountProfile = $Snapshot.profile
    Write-Host ("{0}. {1}" -f $script:MenuProfileNumbers[$accountProfile.id], $accountProfile.label) -ForegroundColor Cyan

    if (-not $Snapshot.signedIn) {
        if ($Snapshot.accountError) {
            Write-Host '    Sign-in or usage status unavailable.' -ForegroundColor DarkYellow
        }
        else {
            Write-Host '    Not signed in. Select this account to open Codex and sign in.' -ForegroundColor DarkYellow
        }
        return
    }

    $plan = $Snapshot.account.planType
    if (-not [string]::IsNullOrWhiteSpace([string]$plan)) {
        Write-Host ("    Signed in ({0})" -f $plan)
    }
    else {
        Write-Host '    Signed in'
    }

    $rateResult = $Snapshot.rateLimits
    if ($null -eq $rateResult) {
        Write-Host '    Usage unavailable for this account.' -ForegroundColor DarkYellow
        if (-not [string]::IsNullOrWhiteSpace($Snapshot.usageError)) {
            Write-Host ("    {0}" -f $Snapshot.usageError) -ForegroundColor DarkGray
        }
        return
    }

    $bucketEntries = @()
    if ($null -ne $rateResult.rateLimitsByLimitId) {
        foreach ($bucketProperty in @($rateResult.rateLimitsByLimitId.PSObject.Properties)) {
            $bucketEntries += [pscustomobject]@{ name = $bucketProperty.Name; value = $bucketProperty.Value }
        }
    }
    elseif ($null -ne $rateResult.rateLimits) {
        $bucketName = [string]$rateResult.rateLimits.limitId
        if ([string]::IsNullOrWhiteSpace($bucketName)) { $bucketName = 'Codex' }
        $bucketEntries += [pscustomobject]@{ name = $bucketName; value = $rateResult.rateLimits }
    }

    $windowsFound = $false
    if ($bucketEntries.Count -gt 0) {
        foreach ($bucketEntry in $bucketEntries) {
            $bucket = $bucketEntry.value
            $bucketLabel = [string]$bucket.limitName
            if ([string]::IsNullOrWhiteSpace($bucketLabel)) { $bucketLabel = [string]$bucket.limitId }
            if ([string]::IsNullOrWhiteSpace($bucketLabel)) { $bucketLabel = [string]$bucketEntry.name }

            foreach ($windowName in @('primary', 'secondary')) {
                $window = $bucket.$windowName
                if ($null -eq $window -or $null -eq $window.usedPercent) { continue }
                $windowsFound = $true
                $duration = 0
                if ($null -ne $window.windowDurationMins) { $duration = [int]$window.windowDurationMins }
                $label = "{0} {1}" -f $bucketLabel, (Get-WindowLabel -DurationMinutes $duration)
                Write-UsageBar -Label $label -UsedPercent ([double]$window.usedPercent) -ResetLabel (Get-ResetLabel -Window $window)
            }
        }
    }

    if (-not $windowsFound) {
        Write-Host '    No active rate-limit windows were returned.' -ForegroundColor DarkYellow
    }
}

function Get-ProfileSnapshots {
    param([Parameter(Mandatory = $true)]$State)

    $snapshots = @()
    foreach ($accountProfile in @($State.profiles)) {
        Write-Host ("Checking {0}..." -f $accountProfile.label) -ForegroundColor DarkGray
        $snapshots += Get-ProfileSnapshot -AccountProfile $accountProfile
    }
    return $snapshots
}

function Start-Profile {
    param([Parameter(Mandatory = $true)]$AccountProfile)

    $codexPath = Get-CodexPath
    $previousEnvironment = @{}
    foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
        $previousEnvironment[$environmentVariable] = [Environment]::GetEnvironmentVariable($environmentVariable, 'Process')
        [Environment]::SetEnvironmentVariable($environmentVariable, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $AccountProfile.home, 'Process')
    try {
        & $codexPath
    }
    finally {
        foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
            [Environment]::SetEnvironmentVariable($environmentVariable, $previousEnvironment[$environmentVariable], 'Process')
        }
    }
}

function Add-Account {
    param([Parameter(Mandatory = $true)]$State)

    $label = Read-Host 'Account label (for example Personal or Work)'
    $label = $label.Trim()
    if ([string]::IsNullOrWhiteSpace($label)) {
        Write-Warning 'The account label cannot be empty.'
        return
    }
    foreach ($existing in @($State.profiles)) {
        if ([string]::Equals([string]$existing.label, $label, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning 'An account with that label already exists.'
            return
        }
    }

    $id = [Guid]::NewGuid().ToString('N')
    $profileHome = Join-Path $script:ProfilesRoot $id
    New-Item -ItemType Directory -Path $profileHome -Force | Out-Null
    $configPath = Join-Path $profileHome 'config.toml'
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($configPath, "cli_auth_credentials_store = `"file`"`r`n", $utf8WithoutBom)

    $profile = [pscustomobject]@{
        id      = $id
        label   = $label
        home    = $profileHome
        managed = $true
    }

    Write-Host "Starting one-time sign-in for '$label'." -ForegroundColor Cyan
    Write-Host 'Complete the browser sign-in, then return to this window.'
    $previousEnvironment = @{}
    foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
        $previousEnvironment[$environmentVariable] = [Environment]::GetEnvironmentVariable($environmentVariable, 'Process')
        [Environment]::SetEnvironmentVariable($environmentVariable, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $profileHome, 'Process')
    try {
        & (Get-CodexPath) login
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Sign-in did not complete. This profile was not added.'
            [void](Read-Host 'Press Enter to continue')
            return
        }
    }
    catch {
        Write-Warning "Sign-in failed. This profile was not added. $($_.Exception.Message)"
        [void](Read-Host 'Press Enter to continue')
        return
    }
    finally {
        foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
            [Environment]::SetEnvironmentVariable($environmentVariable, $previousEnvironment[$environmentVariable], 'Process')
        }
    }

    $snapshot = Get-ProfileSnapshot -AccountProfile $profile
    if (-not $snapshot.signedIn) {
        Write-Warning 'Codex did not confirm a signed-in account. This profile was not added.'
        [void](Read-Host 'Press Enter to continue')
        return
    }

    $State.profiles = @($State.profiles) + @($profile)
    Save-State -State $State
    Write-Host "Added '$label'. Its sign-in is saved on this device." -ForegroundColor Green
    [void](Read-Host 'Press Enter to continue')
}

function Show-MainMenu {
    $state = Get-State
    $codexPath = Get-CodexPath

    while ($true) {
        Clear-Host
        Write-Host 'Codex Account Switcher' -ForegroundColor Cyan
        Write-Host 'Usage is refreshed from Codex when this menu opens.' -ForegroundColor DarkGray
        Write-Host ''

        $script:MenuProfileNumbers = @{}
        $number = 1
        foreach ($profile in @($state.profiles)) {
            $script:MenuProfileNumbers[$profile.id] = $number
            $number++
        }

        if (@($state.profiles).Count -eq 0) {
            Write-Host 'No accounts have been added yet.' -ForegroundColor DarkYellow
        }
        else {
            foreach ($snapshot in @(Get-ProfileSnapshots -State $state)) {
                Write-ProfileSnapshot -Snapshot $snapshot
                Write-Host ''
            }
        }

        Write-Host 'Choose an account number to open Codex.'
        Write-Host 'A. Add account    R. Refresh usage    Q. Quit'
        $choice = (Read-Host 'Selection').Trim()

        if ($choice -match '(?i)^q$') { return }
        if ($choice -match '(?i)^a$') {
            Add-Account -State $state
            $state = Get-State
            continue
        }
        if ($choice -match '(?i)^r$') { continue }

        $selectedNumber = 0
        if ([int]::TryParse($choice, [ref]$selectedNumber) -and $selectedNumber -ge 1 -and $selectedNumber -le @($state.profiles).Count) {
            $selectedProfile = @($state.profiles)[$selectedNumber - 1]
            Start-Profile -AccountProfile $selectedProfile
            continue
        }

        Write-Warning 'Choose a listed number, A, R, or Q.'
        Start-Sleep -Seconds 1
    }
}

try {
    [void](Get-CodexPath)
    Show-MainMenu
}
catch {
    Write-Host "Codex Account Switcher: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
