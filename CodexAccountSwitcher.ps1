param()

$ErrorActionPreference = 'Stop'

$script:DataRoot = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher'
$script:ProfilesRoot = Join-Path $script:DataRoot 'profiles'
$script:StatePath = Join-Path $script:DataRoot 'profiles.json'
$script:ProxyRoot = Join-Path $script:DataRoot 'bin'
$script:RealCodexPathFile = Join-Path $script:DataRoot 'codex-path.txt'
$script:AuthEnvironmentVariables = @(
    'CODEX_HOME',
    'CODEX_ACCESS_TOKEN',
    'OPENAI_API_KEY',
    'OPENAI_IDENTITY_TOKEN_FILE',
    'OPENAI_FEDERATION_RULE_ID'
)
$script:CodexApplication = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

function Broadcast-EnvironmentChange {
    if (-not ('CodexSwitcherEnvironmentBroadcast' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexSwitcherEnvironmentBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
}
'@
    }

    $result = [UIntPtr]::Zero
    [void][CodexSwitcherEnvironmentBroadcast]::SendMessageTimeout([IntPtr](-1), [uint32]0x1A, [UIntPtr]::Zero, 'Environment', [uint32]2, [uint32]1000, [ref]$result)
}

function Get-CodexPath {
    if (Test-Path -LiteralPath $script:RealCodexPathFile) {
        $savedPath = (Get-Content -LiteralPath $script:RealCodexPathFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($savedPath) -and (Test-Path -LiteralPath $savedPath)) {
            return $savedPath
        }
    }

    $codexApplications = @(Get-Command codex -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and -not $_.Source.StartsWith($script:ProxyRoot, [StringComparison]::OrdinalIgnoreCase) })
    if ($codexApplications.Count -gt 0) {
        $script:CodexApplication = $codexApplications[0]
    }

    if ($null -eq $script:CodexApplication -or $script:CodexApplication.Source.StartsWith($script:ProxyRoot, [StringComparison]::OrdinalIgnoreCase)) {
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
                $stateChanged = $false
                foreach ($accountProfile in @($state.profiles)) {
                    if ($accountProfile.id -eq 'default' -and $accountProfile.label -eq 'Default Codex account') {
                        $accountProfile.label = 'Personal'
                        $stateChanged = $true
                    }
                }
                if ($state.PSObject.Properties.Name -notcontains 'selectedProfileId') {
                    Add-Member -InputObject $state -MemberType NoteProperty -Name 'selectedProfileId' -Value $null
                    $stateChanged = $true
                }
                if ([string]::IsNullOrWhiteSpace([string]$state.selectedProfileId)) {
                    $personalProfile = @($state.profiles | Where-Object { $_.id -eq 'default' } | Select-Object -First 1)
                    if ($personalProfile.Count -gt 0) {
                        $state.selectedProfileId = $personalProfile[0].id
                    }
                    elseif (@($state.profiles).Count -gt 0) {
                        $state.selectedProfileId = @($state.profiles)[0].id
                    }
                    $stateChanged = $true
                }
                if ($stateChanged) {
                    Save-State -State $state
                }
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
        version           = 1
        selectedProfileId = 'default'
        profiles          = @(
            [pscustomobject]@{
                id       = 'default'
                label    = 'Personal'
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

    if ($DurationMinutes -eq 10080) { return 'weekly limit' }
    if ($DurationMinutes -eq 1440) { return 'daily limit' }
    if ($DurationMinutes -gt 0 -and ($DurationMinutes % 60) -eq 0) {
        $hours = [int]($DurationMinutes / 60)
        return "$hours hour limit"
    }
    if ($DurationMinutes -gt 0) { return "$DurationMinutes minute limit" }
    return 'usage limit'
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

    Write-Host ('  {0}: [{1}] {2,3}% used / {3,3}% left; {4}' -f $Label, $bar, [int][Math]::Round($used), [int][Math]::Round($remaining), $ResetLabel) -ForegroundColor $color
}

function Write-ProfileSnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][bool]$IsSelected
    )

    $accountProfile = $Snapshot.profile
    $marker = ' '
    if ($IsSelected) { $marker = '*' }
    Write-Host ("{0}{1}. {2}" -f $marker, $Number, $accountProfile.label) -ForegroundColor Cyan

    if (-not $Snapshot.signedIn) {
        if ($Snapshot.accountError) {
            Write-Host '  Sign-in or usage status unavailable.' -ForegroundColor DarkYellow
        }
        else {
            Write-Host '  Not signed in. Select this account to open Codex and sign in.' -ForegroundColor DarkYellow
        }
        return
    }

    $plan = $Snapshot.account.planType
    if (-not [string]::IsNullOrWhiteSpace([string]$plan)) {
        Write-Host ("  Signed in ({0})" -f $plan)
    }
    else {
        Write-Host '  Signed in'
    }

    $rateResult = $Snapshot.rateLimits
    if ($null -eq $rateResult) {
        Write-Host '  Usage unavailable for this account.' -ForegroundColor DarkYellow
        if (-not [string]::IsNullOrWhiteSpace($Snapshot.usageError)) {
            Write-Host ("  {0}" -f $Snapshot.usageError) -ForegroundColor DarkGray
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
            $bucketLabel = [string]$bucket.limitId
            if ([string]::IsNullOrWhiteSpace($bucketLabel)) { $bucketLabel = [string]$bucketEntry.name }
            if ($bucketLabel -eq 'codex') { $bucketLabel = '' }

            foreach ($windowName in @('primary', 'secondary')) {
                $window = $bucket.$windowName
                if ($null -eq $window -or $null -eq $window.usedPercent) { continue }
                $windowsFound = $true
                $duration = 0
                if ($null -ne $window.windowDurationMins) { $duration = [int]$window.windowDurationMins }
                $label = Get-WindowLabel -DurationMinutes $duration
                if (-not [string]::IsNullOrWhiteSpace($bucketLabel)) {
                    $label = "{0} {1}" -f $bucketLabel, $label
                }
                Write-UsageBar -Label $label -UsedPercent ([double]$window.usedPercent) -ResetLabel (Get-ResetLabel -Window $window)
            }
        }
    }

    if (-not $windowsFound) {
        Write-Host '  No active rate-limit windows were returned.' -ForegroundColor DarkYellow
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
    param(
        [Parameter(Mandatory = $true)]$AccountProfile,
        [string]$Message
    )

    $codexPath = Get-CodexPath
    $previousEnvironment = @{}
    foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
        $previousEnvironment[$environmentVariable] = [Environment]::GetEnvironmentVariable($environmentVariable, 'Process')
        [Environment]::SetEnvironmentVariable($environmentVariable, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('CODEX_HOME', $AccountProfile.home, 'Process')
    try {
        if ([string]::IsNullOrWhiteSpace($Message)) {
            & $codexPath
        }
        else {
            & $codexPath $Message
        }
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
    Set-ActiveProfile -State $State -AccountProfile $profile -Quiet
    Write-Host "Added '$label'. Its sign-in is saved on this device." -ForegroundColor Green
    [void](Read-Host 'Press Enter to continue')
}

function Get-SelectedProfile {
    param([Parameter(Mandatory = $true)]$State)

    foreach ($accountProfile in @($State.profiles)) {
        if ($accountProfile.id -eq $State.selectedProfileId) {
            return $accountProfile
        }
    }
    if (@($State.profiles).Count -gt 0) {
        return @($State.profiles)[0]
    }
    return $null
}

function Install-CodexProxy {
    if (-not (Test-Path -LiteralPath $script:ProxyRoot)) {
        New-Item -ItemType Directory -Path $script:ProxyRoot -Force | Out-Null
    }

    $realCodexPath = Get-CodexPath
    if ($realCodexPath.StartsWith($script:ProxyRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The Codex command shim cannot find the original Codex CLI executable.'
    }
    [System.IO.File]::WriteAllText($script:RealCodexPathFile, $realCodexPath, [System.Text.UTF8Encoding]::new($false))

    foreach ($fileName in @('CodexProxy.ps1', 'codex.cmd')) {
        $sourcePath = Join-Path $PSScriptRoot $fileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "The launcher support file '$fileName' is missing. Keep it beside CodexAccountSwitcher.ps1."
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $script:ProxyRoot $fileName) -Force
    }
    Copy-Item -LiteralPath (Join-Path $script:ProxyRoot 'CodexProxy.ps1') -Destination (Join-Path $script:ProxyRoot 'codex.ps1') -Force

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $proxyAlreadyOnUserPath = @($pathEntries | Where-Object { [string]::Equals($_.TrimEnd('\'), $script:ProxyRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if (-not $proxyAlreadyOnUserPath) {
        $newUserPath = $script:ProxyRoot
        if (-not [string]::IsNullOrWhiteSpace($userPath)) { $newUserPath += ";$userPath" }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    }

    $processPathEntries = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $proxyAlreadyOnProcessPath = @($processPathEntries | Where-Object { [string]::Equals($_.TrimEnd('\'), $script:ProxyRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if (-not $proxyAlreadyOnProcessPath) { $env:Path = "$($script:ProxyRoot);$env:Path" }
    Broadcast-EnvironmentChange

    return (-not $proxyAlreadyOnUserPath -or -not $proxyAlreadyOnProcessPath)
}

function Set-ActiveProfile {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$AccountProfile,
        [switch]$Quiet
    )

    # Persist the selection and install a shim so future codex invocations resolve it.
    $State.selectedProfileId = $AccountProfile.id
    Save-State -State $State
    [Environment]::SetEnvironmentVariable('CODEX_HOME', [string]$AccountProfile.home, 'User')
    [Environment]::SetEnvironmentVariable('CODEX_HOME', [string]$AccountProfile.home, 'Process')
    $restartTerminal = Install-CodexProxy

    if (-not $Quiet) {
        Write-Host "Switched to '$($AccountProfile.label)'." -ForegroundColor Green
        if ($restartTerminal) {
            Write-Host 'Close and reopen your terminal application once so it can find the Codex command shim.' -ForegroundColor Yellow
        }
        else {
            Write-Host 'Future codex commands will use this account. A Codex session already running will keep its current account.' -ForegroundColor DarkGray
        }
        [void](Read-Host 'Press Enter to continue')
    }
    elseif ($restartTerminal) {
        Write-Host 'Close and reopen your terminal application once so it can find the Codex command shim.' -ForegroundColor Yellow
    }
}

function Show-Help {
    Write-Host 'Commands:' -ForegroundColor Cyan
    Write-Host '  /help                                  Show this help'
    Write-Host '  /accounts                              Refresh and list accounts'
    Write-Host '  /switch <number>                       Select the active account'
    Write-Host '  /open                                  Open Codex with an empty composer'
    Write-Host '  /add-account                           Sign in to another ChatGPT account'
    Write-Host '  /refresh-usage                         Refresh every account limit'
    Write-Host '  /rename-account <number> <new label>   Rename an account'
    Write-Host '  /quit                                  Exit the switcher'
    Write-Host ''
    Write-Host 'Type a regular message to open Codex with that message for the selected account.' -ForegroundColor DarkGray
    [void](Read-Host 'Press Enter to return')
}

function Read-MenuInput {
    param([Parameter(Mandatory = $true)][string]$Placeholder)

    Write-Host '>: ' -NoNewline
    $origin = $Host.UI.RawUI.CursorPosition
    Write-Host $Placeholder -NoNewline -ForegroundColor DarkGray
    [Console]::SetCursorPosition($origin.X, $origin.Y)

    $characters = New-Object 'System.Collections.Generic.List[char]'
    $cursor = 0
    $renderedLength = 0
    $placeholderVisible = $true

    while ($true) {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $virtualKeyCode = [int]$key.VirtualKeyCode

        if ($placeholderVisible) {
            [Console]::SetCursorPosition($origin.X, $origin.Y)
            [Console]::Write((' ' * $Placeholder.Length))
            [Console]::SetCursorPosition($origin.X, $origin.Y)
            $placeholderVisible = $false
        }

        if ($virtualKeyCode -eq 13) {
            [Console]::SetCursorPosition($origin.X + $cursor, $origin.Y)
            [Console]::WriteLine()
            return -join $characters.ToArray()
        }
        if ($virtualKeyCode -eq 27) {
            [Console]::SetCursorPosition($origin.X, $origin.Y)
            [Console]::Write((' ' * $renderedLength))
            [Console]::SetCursorPosition($origin.X, $origin.Y)
            [Console]::WriteLine()
            return ''
        }
        if ($virtualKeyCode -eq 8 -and $cursor -gt 0) {
            $characters.RemoveAt($cursor - 1)
            $cursor = $cursor - 1
        }
        elseif ($virtualKeyCode -eq 46 -and $cursor -lt $characters.Count) {
            $characters.RemoveAt($cursor)
        }
        elseif ($virtualKeyCode -eq 37 -and $cursor -gt 0) {
            $cursor = $cursor - 1
        }
        elseif ($virtualKeyCode -eq 39 -and $cursor -lt $characters.Count) {
            $cursor = $cursor + 1
        }
        elseif ($virtualKeyCode -eq 36) {
            $cursor = 0
        }
        elseif ($virtualKeyCode -eq 35) {
            $cursor = $characters.Count
        }
        elseif (-not [char]::IsControl($key.Character)) {
            $characters.Insert($cursor, $key.Character)
            $cursor = $cursor + 1
        }

        $line = -join $characters.ToArray()
        [Console]::SetCursorPosition($origin.X, $origin.Y)
        [Console]::Write($line)
        if ($renderedLength -gt $line.Length) {
            [Console]::Write((' ' * ($renderedLength - $line.Length)))
        }
        $renderedLength = $line.Length
        [Console]::SetCursorPosition($origin.X + $cursor, $origin.Y)
    }
}

function Rename-Account {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $profiles = @($State.profiles)
    if ($Number -lt 1 -or $Number -gt $profiles.Count) {
        Write-Warning 'That account number is not in the list.'
        return
    }
    $Label = $Label.Trim()
    if ([string]::IsNullOrWhiteSpace($Label)) {
        Write-Warning 'The account label cannot be empty.'
        return
    }
    foreach ($existing in $profiles) {
        if ($existing.id -ne $profiles[$Number - 1].id -and [string]::Equals([string]$existing.label, $Label, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warning 'An account with that label already exists.'
            return
        }
    }

    $profiles[$Number - 1].label = $Label
    $State.profiles = $profiles
    Save-State -State $State
    Write-Host "Renamed account $Number to '$Label'." -ForegroundColor Green
    [void](Read-Host 'Press Enter to continue')
}

function Show-MainMenu {
    $state = Get-State
    $snapshots = @()
    $refreshNeeded = $true

    while ($true) {
        if ($refreshNeeded) {
            Clear-Host
            Write-Host 'Refreshing Codex account usage...' -ForegroundColor DarkGray
            $snapshots = @(Get-ProfileSnapshots -State $state)
            $refreshNeeded = $false
        }

        Clear-Host
        Write-Host '+--------------------------------------------------------------------------+' -ForegroundColor White
        Write-Host '| Codex Account Switcher                                                   |' -ForegroundColor Cyan
        Write-Host '+--------------------------------------------------------------------------+' -ForegroundColor White

        if ($snapshots.Count -eq 0) {
            Write-Host 'No accounts yet. Use /add-account to sign in.' -ForegroundColor DarkYellow
        }
        else {
            $number = 1
            foreach ($snapshot in $snapshots) {
                $selected = ($snapshot.profile.id -eq $state.selectedProfileId)
                Write-ProfileSnapshot -Snapshot $snapshot -Number $number -IsSelected $selected
                Write-Host ''
                $number++
            }
        }

        Write-Host '+--------------------------------------------------------------------------+' -ForegroundColor White
        $choice = (Read-MenuInput -Placeholder 'number to switch, message to start Codex, /help for commands').Trim()

        if ([string]::IsNullOrWhiteSpace($choice)) { continue }
        if ($choice -match '(?i)^/(quit|exit)$') { return }
        if ($choice -match '(?i)^/help$') {
            Show-Help
            continue
        }
        if ($choice -match '(?i)^/refresh-usage$' -or $choice -match '(?i)^/accounts$') {
            $refreshNeeded = $true
            continue
        }
        if ($choice -match '(?i)^/add-account$') {
            Add-Account -State $state
            $state = Get-State
            $refreshNeeded = $true
            continue
        }
        if ($choice -match '(?i)^/switch\s+(\d+)\s*$') {
            $selectedNumber = [int]$Matches[1]
            $profiles = @($state.profiles)
            if ($selectedNumber -lt 1 -or $selectedNumber -gt $profiles.Count) {
                Write-Warning 'That account number is not in the list.'
                Start-Sleep -Seconds 1
                continue
            }
            Set-ActiveProfile -State $state -AccountProfile $profiles[$selectedNumber - 1]
            continue
        }
        if ($choice -match '^\d+$') {
            $selectedNumber = [int]$choice
            $profiles = @($state.profiles)
            if ($selectedNumber -lt 1 -or $selectedNumber -gt $profiles.Count) {
                Write-Warning 'That account number is not in the list.'
                Start-Sleep -Seconds 1
                continue
            }
            Set-ActiveProfile -State $state -AccountProfile $profiles[$selectedNumber - 1]
            continue
        }
        if ($choice -match '(?i)^/rename-account\s+(\d+)\s+(.+)$') {
            Rename-Account -State $state -Number ([int]$Matches[1]) -Label $Matches[2]
            continue
        }
        if ($choice -match '(?i)^/open$') {
            $selectedProfile = Get-SelectedProfile -State $state
            if ($null -eq $selectedProfile) {
                Write-Warning 'Add an account first with /add-account.'
                Start-Sleep -Seconds 1
                continue
            }
            Start-Profile -AccountProfile $selectedProfile
            $refreshNeeded = $true
            continue
        }
        if ($choice.StartsWith('/')) {
            Write-Warning 'Unknown command. Type /help to see the available commands.'
            Start-Sleep -Seconds 1
            continue
        }

        $selectedProfile = Get-SelectedProfile -State $state
        if ($null -eq $selectedProfile) {
            Write-Warning 'Add an account first with /add-account.'
            Start-Sleep -Seconds 1
            continue
        }
        Start-Profile -AccountProfile $selectedProfile -Message $choice
        $refreshNeeded = $true
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
