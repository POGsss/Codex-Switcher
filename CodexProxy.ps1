param()

$ErrorActionPreference = 'Stop'
$dataRoot = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher'
$profilesRoot = Join-Path $dataRoot 'profiles'
$statePath = Join-Path $dataRoot 'profiles.json'
$realCodexPathFile = Join-Path $dataRoot 'codex-path.txt'

try {
    if (-not (Test-Path -LiteralPath $statePath)) {
        throw 'Codex Account Switcher configuration not found.'
    }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $selectedProfile = @($state.profiles | Where-Object { $_.id -eq $state.selectedProfileId } | Select-Object -First 1)
    if ($selectedProfile.Count -eq 0) {
        throw 'No selected Codex account is saved.'
    }

    $codexPath = (Get-Content -LiteralPath $realCodexPathFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($codexPath) -or -not (Test-Path -LiteralPath $codexPath)) {
        throw 'The original Codex CLI executable is missing. Run the account switcher again to repair the command shim.'
    }

    $shareConvo = ($null -eq $state.shareConversations) -or ($state.shareConversations -eq $true)
    $sharedHome = if ($state.sharedHome) { [string]$state.sharedHome } else { Join-Path $env:USERPROFILE '.codex' }
    $profileId = [string]$selectedProfile[0].id
    $profileDir = Join-Path $profilesRoot $profileId
    $profileAuthFile = Join-Path $profileDir 'auth.json'
    $sharedAuthFile = Join-Path $sharedHome 'auth.json'

    if ($shareConvo) {
        $env:CODEX_HOME = $sharedHome

        # Recover this profile's own auth file if its home already contains one.
        if (-not (Test-Path -LiteralPath $profileAuthFile)) {
            $profileHomeAuthFile = Join-Path ([string]$selectedProfile[0].home) 'auth.json'
            if (Test-Path -LiteralPath $profileHomeAuthFile) {
                if (-not (Test-Path -LiteralPath $profileDir)) {
                    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
                }
                [System.IO.File]::Copy($profileHomeAuthFile, $profileAuthFile, $true)
            }
        }

        if (-not (Test-Path -LiteralPath $profileAuthFile)) {
            throw "The selected profile '$($selectedProfile[0].label)' has no saved sign-in. Add or sign in to this account in Codex Account Switcher first."
        }
        if (-not (Test-Path -LiteralPath $sharedHome)) {
            New-Item -ItemType Directory -Path $sharedHome -Force | Out-Null
        }
        [System.IO.File]::Copy($profileAuthFile, $sharedAuthFile, $true)
    }
    else {
        $env:CODEX_HOME = [string]$selectedProfile[0].home
    }

    & $codexPath --no-daemon @args
    $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }

    # Save refreshed tokens in this account's own profile, whether the CLI used
    # the shared conversation home or the account's isolated home.
    $authHomeAfterRun = if ($shareConvo) { $sharedHome } else { [string]$selectedProfile[0].home }
    $authFileAfterRun = Join-Path $authHomeAfterRun 'auth.json'
    if ((Test-Path -LiteralPath $authFileAfterRun) -and (Test-Path -LiteralPath $profileDir)) {
        try {
            $authAfterRunFullPath = [System.IO.Path]::GetFullPath($authFileAfterRun)
            $profileAuthFullPath = [System.IO.Path]::GetFullPath($profileAuthFile)
            if (-not [string]::Equals($authAfterRunFullPath, $profileAuthFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                [System.IO.File]::Copy($authFileAfterRun, $profileAuthFile, $true)
            }
        }
        catch {}
    }

    exit $exitCode
}
catch {
    [Console]::Error.WriteLine("Codex account switcher: $($_.Exception.Message)")
    exit 1
}
