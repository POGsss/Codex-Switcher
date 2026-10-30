param()

$ErrorActionPreference = 'Stop'

$script:IsWindows = ($env:OS -eq 'Windows_NT')
$script:PathComparison = if ($script:IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$script:HomeRoot = if ($script:IsWindows) { $env:USERPROFILE } else { $HOME }
if ($script:IsWindows) {
    $script:DataRoot = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher'
}
elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
    $script:DataRoot = Join-Path $script:HomeRoot 'Library/Application Support/CodexAccountSwitcher'
}
else {
    $dataHome = if (-not [string]::IsNullOrWhiteSpace($env:XDG_DATA_HOME)) { $env:XDG_DATA_HOME } else { Join-Path $script:HomeRoot '.local/share' }
    $script:DataRoot = Join-Path $dataHome 'CodexAccountSwitcher'
}
$script:ProfilesRoot = Join-Path $script:DataRoot 'profiles'
$script:StatePath = Join-Path $script:DataRoot 'profiles.json'
$script:ProxyRoot = Join-Path $script:DataRoot 'bin'
$script:RealCodexPathFile = Join-Path $script:DataRoot 'codex-path.txt'
$script:DefaultCodexHome = Join-Path $script:HomeRoot '.codex'
if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME) -and -not $env:CODEX_HOME.StartsWith($script:ProfilesRoot, $script:PathComparison)) {
    $script:DefaultCodexHome = $env:CODEX_HOME
}
$script:SharedHome = Join-Path $script:DataRoot 'shared'

$script:AuthEnvironmentVariables = @(
    'CODEX_HOME',
    'CODEX_ACCESS_TOKEN',
    'OPENAI_API_KEY',
    'OPENAI_IDENTITY_TOKEN_FILE',
    'OPENAI_FEDERATION_RULE_ID'
)
$script:CodexApplication = Get-Command codex -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

function Broadcast-EnvironmentChange {
    if (-not $script:IsWindows) { return }

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

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $Path.TrimEnd([char[]]@('\', '/'))
    }
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $rootPath.Length) {
        $fullPath = $fullPath.TrimEnd([char[]]@('\', '/'))
    }
    return $fullPath
}

function Get-CodexPath {
    if (Test-Path -LiteralPath $script:RealCodexPathFile) {
        $savedPath = (Get-Content -LiteralPath $script:RealCodexPathFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($savedPath) -and (Test-Path -LiteralPath $savedPath)) {
            return $savedPath
        }
    }

    $codexApplications = @(Get-Command codex -CommandType Application -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and -not $_.Source.StartsWith($script:ProxyRoot, $script:PathComparison) })
    if ($codexApplications.Count -gt 0) {
        $script:CodexApplication = $codexApplications[0]
    }

    if ($null -eq $script:CodexApplication -or $script:CodexApplication.Source.StartsWith($script:ProxyRoot, $script:PathComparison)) {
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

function Sync-ProfileAuth {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [string]$SharedHome = $script:SharedHome,
        [string]$SourceHome
    )

    $authHome = if ($SourceHome) { $SourceHome } else { $SharedHome }
    $sourceAuth = Join-Path $authHome 'auth.json'
    $profileDir = Join-Path $script:ProfilesRoot $ProfileId
    $profileAuth = Join-Path $profileDir 'auth.json'

    if ((Test-Path -LiteralPath $sourceAuth) -and (Test-Path -LiteralPath $profileDir)) {
        try {
            $sourceFullPath = [System.IO.Path]::GetFullPath($sourceAuth)
            $profileFullPath = [System.IO.Path]::GetFullPath($profileAuth)
            if (-not [string]::Equals($sourceFullPath, $profileFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                [System.IO.File]::Copy($sourceAuth, $profileAuth, $true)
            }
        }
        catch {}
    }
}

function Deploy-ProfileAuth {
    param(
        [Parameter(Mandatory = $true)][string]$ProfileId,
        [string]$SharedHome = $script:SharedHome
    )

    $profileDir = Join-Path $script:ProfilesRoot $ProfileId
    $profileAuth = Join-Path $profileDir 'auth.json'
    $sharedAuth = Join-Path $SharedHome 'auth.json'

    if (Test-Path -LiteralPath $profileAuth) {
        if (-not (Test-Path -LiteralPath $SharedHome)) {
            New-Item -ItemType Directory -Path $SharedHome -Force | Out-Null
        }
        $needCopy = $true
        if (Test-Path -LiteralPath $sharedAuth) {
            try {
                $pBytes = [System.IO.File]::ReadAllBytes($profileAuth)
                $sBytes = [System.IO.File]::ReadAllBytes($sharedAuth)
                if ($pBytes.Length -eq $sBytes.Length) {
                    $identical = $true
                    for ($i = 0; $i -lt $pBytes.Length; $i++) {
                        if ($pBytes[$i] -ne $sBytes[$i]) {
                            $identical = $false
                            break
                        }
                    }
                    if ($identical) { $needCopy = $false }
                }
            }
            catch {}
        }
        if ($needCopy) {
            [System.IO.File]::Copy($profileAuth, $sharedAuth, $true)
        }
    }
}

function Import-ProfileConversations {
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [string]$SharedHome = $script:SharedHome
    )

    $sourceHome = [string]$Profile.home
    if ([string]::IsNullOrWhiteSpace($sourceHome) -or -not (Test-Path -LiteralPath $sourceHome)) {
        return
    }
    try {
        $sourceFullPath = Get-NormalizedFullPath -Path $sourceHome
        $sharedFullPath = Get-NormalizedFullPath -Path $SharedHome
    }
    catch {
        return
    }
    if ([string]::Equals($sourceFullPath, $sharedFullPath, $script:PathComparison)) {
        return
    }
    if (-not (Test-Path -LiteralPath $SharedHome)) {
        New-Item -ItemType Directory -Path $SharedHome -Force | Out-Null
    }

    # 1. Copy missing rollout files from sessions directory
    $srcSessions = Join-Path $sourceHome 'sessions'
    $dstSessions = Join-Path $SharedHome 'sessions'
    if (Test-Path -LiteralPath $srcSessions) {
        if (-not (Test-Path -LiteralPath $dstSessions)) {
            New-Item -ItemType Directory -Path $dstSessions -Force | Out-Null
        }
        $rolloutFiles = Get-ChildItem -LiteralPath $srcSessions -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
        foreach ($file in $rolloutFiles) {
            $relPath = $file.FullName.Substring($srcSessions.Length).TrimStart([char[]]@('\', '/'))
            $targetPath = Join-Path $dstSessions $relPath
            if (-not (Test-Path -LiteralPath $targetPath)) {
                $targetDir = [System.IO.Path]::GetDirectoryName($targetPath)
                if (-not (Test-Path -LiteralPath $targetDir)) {
                    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
            }
        }
    }

    # 2. Merge session_index.jsonl
    $srcIndex = Join-Path $sourceHome 'session_index.jsonl'
    $dstIndex = Join-Path $SharedHome 'session_index.jsonl'
    if (Test-Path -LiteralPath $srcIndex) {
        $existingLines = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        if (Test-Path -LiteralPath $dstIndex) {
            foreach ($line in [System.IO.File]::ReadAllLines($dstIndex)) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    [void]$existingLines.Add($line.Trim())
                }
            }
        }
        $newLines = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in [System.IO.File]::ReadAllLines($srcIndex)) {
            $trimmed = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $existingLines.Contains($trimmed)) {
                [void]$newLines.Add($trimmed)
                [void]$existingLines.Add($trimmed)
            }
        }
        if ($newLines.Count -gt 0) {
            [System.IO.File]::AppendAllLines($dstIndex, $newLines, [System.Text.UTF8Encoding]::new($false))
        }
    }

    # 3. Merge history.jsonl
    $srcHist = Join-Path $sourceHome 'history.jsonl'
    $dstHist = Join-Path $SharedHome 'history.jsonl'
    if (Test-Path -LiteralPath $srcHist) {
        $existingHist = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        if (Test-Path -LiteralPath $dstHist) {
            foreach ($line in [System.IO.File]::ReadAllLines($dstHist)) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    [void]$existingHist.Add($line.Trim())
                }
            }
        }
        $newHist = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in [System.IO.File]::ReadAllLines($srcHist)) {
            $trimmed = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $existingHist.Contains($trimmed)) {
                [void]$newHist.Add($trimmed)
                [void]$existingHist.Add($trimmed)
            }
        }
        if ($newHist.Count -gt 0) {
            [System.IO.File]::AppendAllLines($dstHist, $newHist, [System.Text.UTF8Encoding]::new($false))
        }
    }

    # 4. Merge the Codex SQLite stores using SQLite's backup API so committed WAL data is included.
    $pythonCmd = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pythonCmd) {
        $srcStateDb = Join-Path $sourceHome 'state_5.sqlite'
        $dstStateDb = Join-Path $SharedHome 'state_5.sqlite'
        $srcHistoryDb = Join-Path $sourceHome 'thread_history_1.sqlite'
        $dstHistoryDb = Join-Path $SharedHome 'thread_history_1.sqlite'

        if ((Test-Path -LiteralPath $srcStateDb) -or (Test-Path -LiteralPath $srcHistoryDb)) {
            $mergePyPath = Join-Path $script:DataRoot 'merge-db.py'
            $pyCode = @'
import os, sqlite3, sys, traceback

def quote(identifier):
    return '"' + identifier.replace('"', '""') + '"'

def merge_db(src_path, dst_path, table_names):
    if not os.path.isfile(src_path):
        return
    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    if not os.path.isfile(dst_path):
        with sqlite3.connect(src_path, timeout=15) as source, sqlite3.connect(dst_path, timeout=15) as destination:
            source.backup(destination)
        return

    conn = sqlite3.connect(dst_path, timeout=15)
    try:
        conn.execute('PRAGMA foreign_keys=OFF')
        conn.execute('ATTACH DATABASE ? AS src', (src_path,))
        for table_name in table_names:
            table_id = quote(table_name)
            source_cols = [row[1] for row in conn.execute(f'PRAGMA src.table_info({table_id})')]
            if not source_cols:
                continue
            target_cols = [row[1] for row in conn.execute(f'PRAGMA main.table_info({table_id})')]
            if not target_cols:
                ddl = conn.execute(
                    "SELECT sql FROM src.sqlite_master WHERE type='table' AND name=?",
                    (table_name,),
                ).fetchone()
                if not ddl or not ddl[0]:
                    continue
                conn.execute(ddl[0])
                target_cols = [row[1] for row in conn.execute(f'PRAGMA main.table_info({table_id})')]
            common_cols = [name for name in target_cols if name in source_cols]
            if not common_cols:
                continue
            cols_sql = ', '.join(quote(name) for name in common_cols)
            conn.execute(
                f'INSERT OR IGNORE INTO main.{table_id} ({cols_sql}) '
                f'SELECT {cols_sql} FROM src.{table_id}'
            )
        conn.commit()
    finally:
        try:
            conn.execute('DETACH DATABASE src')
        except sqlite3.Error:
            pass
        conn.close()

if len(sys.argv) >= 5:
    src_state, dst_state, src_hist, dst_hist = sys.argv[1:5]
    try:
        merge_db(src_state, dst_state, ['threads'])
        merge_db(src_hist, dst_hist, ['thread_turns', 'thread_items'])
    except Exception:
        traceback.print_exc()
        sys.exit(1)
'@
            try {
                [System.IO.File]::WriteAllText($mergePyPath, $pyCode, [System.Text.UTF8Encoding]::new($false))
                & $pythonCmd.Source $mergePyPath $srcStateDb $dstStateDb $srcHistoryDb $dstHistoryDb
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Could not merge Codex conversation database from '$sourceHome'. The session files were still copied."
                }
            }
            catch {
                Write-Warning "Could not merge Codex conversation database from '$sourceHome'. Details: $($_.Exception.Message)"
            }
        }
    }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:DataRoot)) {
        New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $script:ProfilesRoot)) {
        New-Item -ItemType Directory -Path $script:ProfilesRoot -Force | Out-Null
    }

    $state = $null
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "The account list could not be read. A backup is saved as profiles.json.broken. Details: $($_.Exception.Message)"
            Copy-Item -LiteralPath $script:StatePath -Destination (Join-Path $script:DataRoot 'profiles.json.broken') -Force
        }
    }

    $stateChanged = $false
    if ($null -eq $state -or $null -eq $state.profiles) {
        $state = [pscustomobject]@{
            version            = 1
            selectedProfileId  = 'default'
            shareConversations = $true
            sharedHome         = $script:SharedHome
            profiles           = @(
                [pscustomobject]@{
                    id       = 'default'
                    label    = 'Personal'
                    home     = $script:DefaultCodexHome
                    managed  = $false
                }
            )
        }
        $stateChanged = $true
    }
    else {
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
        if ($state.PSObject.Properties.Name -notcontains 'shareConversations') {
            Add-Member -InputObject $state -MemberType NoteProperty -Name 'shareConversations' -Value $true
            $stateChanged = $true
        }
        if ($null -eq $state.shareConversations) {
            $state.shareConversations = $true
            $stateChanged = $true
        }
        if ($state.PSObject.Properties.Name -notcontains 'sharedHome') {
            Add-Member -InputObject $state -MemberType NoteProperty -Name 'sharedHome' -Value $script:SharedHome
            $stateChanged = $true
        }
        if ([string]::IsNullOrWhiteSpace([string]$state.sharedHome)) {
            $state.sharedHome = $script:SharedHome
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
    }

    # A shared store must be separate from every profile home so turning sharing
    # off returns each account to its own conversation history.
    $legacySharedHome = [string]$state.sharedHome
    $sharedHomeMatchesProfile = $false
    foreach ($accountProfile in @($state.profiles)) {
        if ([string]::IsNullOrWhiteSpace([string]$accountProfile.home)) { continue }
        try {
            $profileHomeFull = Get-NormalizedFullPath -Path ([string]$accountProfile.home)
            $sharedHomeFull = Get-NormalizedFullPath -Path $legacySharedHome
            if ([string]::Equals($profileHomeFull, $sharedHomeFull, $script:PathComparison)) {
                $sharedHomeMatchesProfile = $true
                break
            }
        }
        catch {}
    }
    if ($sharedHomeMatchesProfile) {
        $state.sharedHome = $script:SharedHome
        $stateChanged = $true
    }

    # Ensure default profile has dedicated auth storage
    $defaultProfileDir = Join-Path $script:ProfilesRoot 'default'
    if (-not (Test-Path -LiteralPath $defaultProfileDir)) {
        New-Item -ItemType Directory -Path $defaultProfileDir -Force | Out-Null
    }
    $defaultAuthFile = Join-Path $defaultProfileDir 'auth.json'
    if (-not (Test-Path -LiteralPath $defaultAuthFile)) {
        $defaultProfile = @($state.profiles | Where-Object { $_.id -eq 'default' } | Select-Object -First 1)
        if ($defaultProfile.Count -gt 0) {
            $defaultHomeAuth = Join-Path ([string]$defaultProfile[0].home) 'auth.json'
            if (Test-Path -LiteralPath $defaultHomeAuth) {
                Copy-Item -LiteralPath $defaultHomeAuth -Destination $defaultAuthFile -Force
            }
        }
    }
    $defaultConfigFile = Join-Path $defaultProfileDir 'config.toml'
    if (-not (Test-Path -LiteralPath $defaultConfigFile)) {
        $defaultProfile = @($state.profiles | Where-Object { $_.id -eq 'default' } | Select-Object -First 1)
        $defaultHomeConfig = if ($defaultProfile.Count -gt 0) { Join-Path ([string]$defaultProfile[0].home) 'config.toml' } else { $null }
        if ($defaultHomeConfig -and (Test-Path -LiteralPath $defaultHomeConfig)) {
            Copy-Item -LiteralPath $defaultHomeConfig -Destination $defaultConfigFile -Force
        }
        else {
            [System.IO.File]::WriteAllText($defaultConfigFile, "cli_auth_credentials_store = `"file`"`r`n", [System.Text.UTF8Encoding]::new($false))
        }
    }

    $activeSharedHome = [string]$state.sharedHome
    if (-not (Test-Path -LiteralPath $activeSharedHome)) {
        New-Item -ItemType Directory -Path $activeSharedHome -Force | Out-Null
    }
    $sharedConfigFile = Join-Path $activeSharedHome 'config.toml'
    if (-not (Test-Path -LiteralPath $sharedConfigFile)) {
        $defaultProfile = @($state.profiles | Where-Object { $_.id -eq 'default' } | Select-Object -First 1)
        if ($defaultProfile.Count -gt 0) {
            $defaultHomeConfig = Join-Path ([string]$defaultProfile[0].home) 'config.toml'
            if (Test-Path -LiteralPath $defaultHomeConfig) {
                Copy-Item -LiteralPath $defaultHomeConfig -Destination $sharedConfigFile -Force
            }
        }
        if (-not (Test-Path -LiteralPath $sharedConfigFile)) {
            [System.IO.File]::WriteAllText($sharedConfigFile, "cli_auth_credentials_store = `"file`"`r`n", [System.Text.UTF8Encoding]::new($false))
        }
    }

    if ($state.shareConversations) {
        # Consolidate existing conversations from all profiles into shared home
        foreach ($accountProfile in @($state.profiles)) {
            Import-ProfileConversations -Profile $accountProfile -SharedHome $activeSharedHome
        }
        if (-not [string]::IsNullOrWhiteSpace($legacySharedHome) -and -not $sharedHomeMatchesProfile) {
            $legacySharedProfile = [pscustomobject]@{ home = $legacySharedHome }
            Import-ProfileConversations -Profile $legacySharedProfile -SharedHome $activeSharedHome
        }
        # Ensure active profile credentials are deployed to shared home
        if (-not [string]::IsNullOrWhiteSpace([string]$state.selectedProfileId)) {
            Deploy-ProfileAuth -ProfileId $state.selectedProfileId -SharedHome $activeSharedHome
        }
    }

    if ($stateChanged) {
        Save-State -State $state
    }
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

function Get-ProfileAuthHome {
    param([Parameter(Mandatory = $true)]$AccountProfile)

    $profileDir = Join-Path $script:ProfilesRoot $AccountProfile.id
    if (Test-Path -LiteralPath (Join-Path $profileDir 'auth.json')) {
        return $profileDir
    }
    return [string]$AccountProfile.home
}

function Get-ProfileSnapshot {
    param([Parameter(Mandatory = $true)]$AccountProfile)

    $snapshot = [pscustomobject]@{
        profile      = $AccountProfile
        account      = $null
        rateLimits   = $null
        signedIn     = $false
        usageError   = $null
        accountError = $null
    }

    $authHome = Get-ProfileAuthHome -AccountProfile $AccountProfile
    try {
        $accountResult = Invoke-AppServerRequest -CodexHome $authHome -Method 'account/read' -ParametersJson '{"refreshToken":false}'
        $snapshot.account = $accountResult.account
        $snapshot.signedIn = ($null -ne $accountResult.account)
        if ($snapshot.signedIn) {
            try {
                $limitResult = Invoke-AppServerRequest -CodexHome $authHome -Method 'account/rateLimits/read'
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

    if ($DurationMinutes -eq 43200) { return 'monthly limit' }
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
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$AccountProfile,
        [string]$Message,
        [switch]$Resume
    )

    $codexPath = Get-CodexPath
    $previousEnvironment = @{}
    $shareConvo = ($null -eq $State.shareConversations) -or ($State.shareConversations -eq $true)
    $sharedHome = if ($State.sharedHome) { [string]$State.sharedHome } else { $script:SharedHome }
    $authDeployed = $false

    try {
        foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
            $previousEnvironment[$environmentVariable] = [Environment]::GetEnvironmentVariable($environmentVariable, 'Process')
            [Environment]::SetEnvironmentVariable($environmentVariable, $null, 'Process')
        }

        if ($shareConvo) {
            $profileAuthFile = Join-Path (Join-Path $script:ProfilesRoot $AccountProfile.id) 'auth.json'
            if (-not (Test-Path -LiteralPath $profileAuthFile)) {
                throw "The selected profile '$($AccountProfile.label)' has no saved sign-in. Add or sign in to this account in Codex Account Switcher first."
            }
            Deploy-ProfileAuth -ProfileId $AccountProfile.id -SharedHome $sharedHome
            $authDeployed = $true
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $sharedHome, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable('CODEX_HOME', $AccountProfile.home, 'Process')
        }

        if ($Resume) {
            & $codexPath --no-daemon resume
        }
        elseif ([string]::IsNullOrWhiteSpace($Message)) {
            & $codexPath --no-daemon
        }
        else {
            & $codexPath --no-daemon $Message
        }
    }
    finally {
        if ($shareConvo -and $authDeployed) {
            Sync-ProfileAuth -ProfileId $AccountProfile.id -SharedHome $sharedHome
        }
        elseif (-not $shareConvo) {
            Sync-ProfileAuth -ProfileId $AccountProfile.id -SourceHome ([string]$AccountProfile.home)
        }
        foreach ($environmentVariable in $script:AuthEnvironmentVariables) {
            if ($previousEnvironment.ContainsKey($environmentVariable)) {
                [Environment]::SetEnvironmentVariable($environmentVariable, $previousEnvironment[$environmentVariable], 'Process')
            }
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
        & (Get-CodexPath) --no-daemon login
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

    $shareConvo = ($null -eq $State.shareConversations) -or ($State.shareConversations -eq $true)
    if ($shareConvo) {
        $sharedHome = if ($State.sharedHome) { [string]$State.sharedHome } else { $script:SharedHome }
        Import-ProfileConversations -Profile $profile -SharedHome $sharedHome
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
    if ($realCodexPath.StartsWith($script:ProxyRoot, $script:PathComparison)) {
        throw 'The Codex command shim cannot find the original Codex CLI executable.'
    }
    [System.IO.File]::WriteAllText($script:RealCodexPathFile, $realCodexPath, [System.Text.UTF8Encoding]::new($false))

    $baseDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($baseDir) -or -not (Test-Path -LiteralPath $baseDir)) {
        if ($MyInvocation.MyCommand.Path -and (Test-Path -LiteralPath $MyInvocation.MyCommand.Path)) {
            $baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
        else {
            $baseDir = (Get-Location).Path
        }
    }

    $supportFiles = if ($script:IsWindows) { @('CodexProxy.ps1', 'codex.cmd') } else { @('CodexProxy.ps1') }
    foreach ($fileName in $supportFiles) {
        $sourcePath = Join-Path $baseDir $fileName
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "The launcher support file '$fileName' is missing. Keep it beside CodexSwitcher.ps1."
        }
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $script:ProxyRoot $fileName) -Force
    }

    $pathSeparator = [string][System.IO.Path]::PathSeparator
    $processPathEntries = @($env:Path -split [regex]::Escape($pathSeparator) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $proxyAlreadyOnProcessPath = @($processPathEntries | Where-Object {
        [string]::Equals((Get-NormalizedFullPath -Path $_), (Get-NormalizedFullPath -Path $script:ProxyRoot), $script:PathComparison)
    }).Count -gt 0

    if ($script:IsWindows) {
        Copy-Item -LiteralPath (Join-Path $script:ProxyRoot 'CodexProxy.ps1') -Destination (Join-Path $script:ProxyRoot 'codex.ps1') -Force
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $pathEntries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $proxyAlreadyOnUserPath = @($pathEntries | Where-Object {
            [string]::Equals((Get-NormalizedFullPath -Path $_), (Get-NormalizedFullPath -Path $script:ProxyRoot), $script:PathComparison)
        }).Count -gt 0
        if (-not $proxyAlreadyOnUserPath) {
            $newUserPath = $script:ProxyRoot
            if (-not [string]::IsNullOrWhiteSpace($userPath)) { $newUserPath += ";$userPath" }
            [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        }
        if (-not $proxyAlreadyOnProcessPath) { $env:Path = "$($script:ProxyRoot);$env:Path" }
        Broadcast-EnvironmentChange
        return (-not $proxyAlreadyOnUserPath -or -not $proxyAlreadyOnProcessPath)
    }

    $proxyScriptPath = Join-Path $script:ProxyRoot 'CodexProxy.ps1'
    $shellQuotedProxyScriptPath = $proxyScriptPath.Replace("'", "'\''")
    $shimPath = Join-Path $script:ProxyRoot 'codex'
    $shimContents = "#!/bin/sh`nexec pwsh -NoLogo -NoProfile -File '$shellQuotedProxyScriptPath' `"`$@`"`n"
    [System.IO.File]::WriteAllText($shimPath, $shimContents, [System.Text.UTF8Encoding]::new($false))
    $chmod = Get-Command chmod -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $chmod) { throw 'The chmod utility is required to install the macOS Codex command shim.' }
    & $chmod.Source '+x' $shimPath
    if ($LASTEXITCODE -ne 0) { throw 'Could not mark the macOS Codex command shim as executable.' }

    if (-not $proxyAlreadyOnProcessPath) { $env:Path = "$($script:ProxyRoot)$pathSeparator$env:Path" }
    $shellName = [System.IO.Path]::GetFileNameWithoutExtension([string]$env:SHELL)
    if ($shellName -eq 'bash') {
        $shellProfilePath = Join-Path $script:HomeRoot '.bash_profile'
        $shellQuotedProxyRoot = $script:ProxyRoot.Replace("'", "'\''")
        $pathLine = "export PATH='$shellQuotedProxyRoot':`$PATH"
    }
    elseif ($shellName -eq 'fish') {
        $fishConfigRoot = Join-Path $script:HomeRoot '.config/fish/conf.d'
        if (-not (Test-Path -LiteralPath $fishConfigRoot)) {
            New-Item -ItemType Directory -Path $fishConfigRoot -Force | Out-Null
        }
        $shellProfilePath = Join-Path $fishConfigRoot 'codex-account-switcher.fish'
        $fishQuotedProxyRoot = $script:ProxyRoot.Replace('\', '\\').Replace("'", "\'")
        $pathLine = "set -gx PATH '$fishQuotedProxyRoot' `$PATH"
    }
    else {
        $shellProfilePath = Join-Path $script:HomeRoot '.zprofile'
        $shellQuotedProxyRoot = $script:ProxyRoot.Replace("'", "'\''")
        $pathLine = "export PATH='$shellQuotedProxyRoot':`$PATH"
    }
    $shellProfileContent = if (Test-Path -LiteralPath $shellProfilePath) { [System.IO.File]::ReadAllText($shellProfilePath) } else { '' }
    $proxyAlreadyOnShellPath = $shellProfileContent.Contains('# Added by Codex Account Switcher') -or $shellProfileContent.Contains($script:ProxyRoot)
    if (-not $proxyAlreadyOnShellPath) {
        $addition = "`n# Added by Codex Account Switcher`n$pathLine`n"
        [System.IO.File]::AppendAllText($shellProfilePath, $addition, [System.Text.UTF8Encoding]::new($false))
    }

    return (-not $proxyAlreadyOnShellPath -or -not $proxyAlreadyOnProcessPath)
}

function Set-ActiveProfile {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$AccountProfile,
        [switch]$Quiet,
        [switch]$SkipPreviousAuthSync
    )

    $shareConvo = ($null -eq $State.shareConversations) -or ($State.shareConversations -eq $true)
    $sharedHome = if ($State.sharedHome) { [string]$State.sharedHome } else { $script:SharedHome }

    if ($shareConvo) {
        if (-not $SkipPreviousAuthSync -and -not [string]::IsNullOrWhiteSpace([string]$State.selectedProfileId)) {
            Sync-ProfileAuth -ProfileId $State.selectedProfileId -SharedHome $sharedHome
        }
        Deploy-ProfileAuth -ProfileId $AccountProfile.id -SharedHome $sharedHome

        if ($script:IsWindows) { [Environment]::SetEnvironmentVariable('CODEX_HOME', $sharedHome, 'User') }
        [Environment]::SetEnvironmentVariable('CODEX_HOME', $sharedHome, 'Process')
    }
    else {
        if ($script:IsWindows) { [Environment]::SetEnvironmentVariable('CODEX_HOME', [string]$AccountProfile.home, 'User') }
        [Environment]::SetEnvironmentVariable('CODEX_HOME', [string]$AccountProfile.home, 'Process')
    }

    $State.selectedProfileId = $AccountProfile.id
    Save-State -State $State
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

function Set-ConversationMode {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][bool]$Shared
    )

    $currentlyShared = ($null -eq $State.shareConversations) -or ($State.shareConversations -eq $true)
    if ($currentlyShared -eq $Shared) {
        $script:MenuNotification = 'Conversation sharing preference is already set.'
        return
    }

    $selectedProfile = Get-SelectedProfile -State $State
    $sharedHome = if ($State.sharedHome) { [string]$State.sharedHome } else { $script:SharedHome }
    if ($currentlyShared -and -not $Shared -and $null -ne $selectedProfile) {
        # Save the selected account's latest refreshed token before leaving the shared home.
        Sync-ProfileAuth -ProfileId $selectedProfile.id -SharedHome $sharedHome
        $profileAuth = Join-Path (Join-Path $script:ProfilesRoot $selectedProfile.id) 'auth.json'
        $isolatedAuth = Join-Path ([string]$selectedProfile.home) 'auth.json'
        if (Test-Path -LiteralPath $profileAuth) {
            try {
                $profileAuthFullPath = [System.IO.Path]::GetFullPath($profileAuth)
                $isolatedAuthFullPath = [System.IO.Path]::GetFullPath($isolatedAuth)
                if (-not [string]::Equals($profileAuthFullPath, $isolatedAuthFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $isolatedHome = [System.IO.Path]::GetDirectoryName($isolatedAuthFullPath)
                    if (-not (Test-Path -LiteralPath $isolatedHome)) {
                        New-Item -ItemType Directory -Path $isolatedHome -Force | Out-Null
                    }
                    [System.IO.File]::Copy($profileAuth, $isolatedAuth, $true)
                }
            }
            catch {
                Write-Warning "Could not prepare '$($selectedProfile.label)' for isolated mode. Details: $($_.Exception.Message)"
            }
        }
    }

    $State.shareConversations = $Shared
    Save-State -State $State

    if ($null -ne $selectedProfile) {
        Set-ActiveProfile -State $State -AccountProfile $selectedProfile -Quiet -SkipPreviousAuthSync:$Shared
    }

    if ($Shared) {
        foreach ($profile in @($State.profiles)) {
            Import-ProfileConversations -Profile $profile -SharedHome $sharedHome
        }
    }
    $script:MenuNotification = 'Conversation sharing preference saved.'
}

function Show-Help {
    Write-Host 'Commands:' -ForegroundColor Cyan
    Write-Host '  /help                                  Show this help'
    Write-Host '  /accounts                              Refresh and list accounts'
    Write-Host '  /switch <number>                       Select the active account'
    Write-Host '  /open                                  Open Codex with an empty composer'
    Write-Host '  /resume                                Show conversations and resume one'
    Write-Host '  /add-account                           Sign in to another ChatGPT account'
    Write-Host '  /refresh-usage                         Refresh every account limit'
    Write-Host '  /rename-account <number> <new label>   Rename an account'

    Write-Host '  /shared-convo [on|off]                 Turn conversation sharing on or off'
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
    [Console]::SetCursorPosition($origin.X + $Placeholder.Length, $origin.Y)

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
        $banner = @(
            ' ██████  ██████  ██████  ███████ ██   ██     ███████ ██     ██ ██ ████████  ██████ ██   ██ ███████ ██████'
            '██      ██    ██ ██   ██ ██       ██ ██      ██      ██     ██ ██    ██    ██      ██   ██ ██      ██   ██'
            '██      ██    ██ ██   ██ █████     ███       ███████ ██  █  ██ ██    ██    ██      ███████ █████   ██████'
            '██      ██    ██ ██   ██ ██       ██ ██           ██ ██ ███ ██ ██    ██    ██      ██   ██ ██      ██   ██'
            ' ██████  ██████  ██████  ███████ ██   ██     ███████  ███ ███  ██    ██     ██████ ██   ██ ███████ ██   ██'
        )
        $terminalWidth = 80
        try {
            $terminalWidth = [int]$Host.UI.RawUI.WindowSize.Width
        }
        catch { }
        if ($terminalWidth -lt 3) { $terminalWidth = 80 }

        $bannerWidth = 0
        foreach ($line in $banner) {
            $bannerWidth = [Math]::Max($bannerWidth, $line.Length)
        }
        $bannerLeftPadding = [int][Math]::Max(0, [Math]::Floor(($terminalWidth - $bannerWidth) / 2))
        $divider = '+' + ('-' * ($terminalWidth - 2)) + '+'
        Write-Host $divider -ForegroundColor White
        foreach ($line in $banner) {
            Write-Host ((' ' * $bannerLeftPadding) + $line.PadRight($bannerWidth)) -ForegroundColor Cyan
        }
        Write-Host $divider -ForegroundColor White
        if (-not [string]::IsNullOrWhiteSpace($script:MenuNotification)) {
            Write-Host "  $script:MenuNotification" -ForegroundColor Cyan
            $script:MenuNotification = $null
        }
        Write-Host ''

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

        Write-Host $divider -ForegroundColor White
        $choice = (Read-MenuInput -Placeholder 'number to switch, /add-account, /resume, /help, or type a message').Trim()

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
        if ($choice -match '(?i)^/(shared-convo|convo-mode|share-convo)(\s+(.+))?$') {
            $arg = if ($Matches[3]) { $Matches[3].Trim().ToLowerInvariant() } else { '' }
            if ($arg -in @('on', 'enable', 'true', '1')) {
                Set-ConversationMode -State $state -Shared $true
            }
            elseif ($arg -in @('off', 'disable', 'false', '0')) {
                Set-ConversationMode -State $state -Shared $false
            }
            elseif ($arg -eq '' -or $arg -eq 'toggle') {
                $currentlyShared = ($null -eq $state.shareConversations) -or ($state.shareConversations -eq $true)
                Set-ConversationMode -State $state -Shared (-not $currentlyShared)
            }
            elseif ($arg -eq 'status') {
                $script:MenuNotification = "Use '/shared-convo on' or '/shared-convo off' to set conversation sharing."
            }
            else {
                $script:MenuNotification = "Unrecognized option '$arg'. Use '/shared-convo on', '/shared-convo off', or '/shared-convo' to toggle."
            }
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
            Start-Profile -State $state -AccountProfile $selectedProfile
            $refreshNeeded = $true
            continue
        }
        if ($choice -match '(?i)^/resume$') {
            $selectedProfile = Get-SelectedProfile -State $state
            if ($null -eq $selectedProfile) {
                Write-Warning 'Add an account first with /add-account.'
                Start-Sleep -Seconds 1
                continue
            }
            Start-Profile -State $state -AccountProfile $selectedProfile -Resume
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
        Start-Profile -State $state -AccountProfile $selectedProfile -Message $choice
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
