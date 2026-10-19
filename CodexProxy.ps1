param()

$ErrorActionPreference = 'Stop'
$dataRoot = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher'
$statePath = Join-Path $dataRoot 'profiles.json'
$realCodexPathFile = Join-Path $dataRoot 'codex-path.txt'

try {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $selectedProfile = @($state.profiles | Where-Object { $_.id -eq $state.selectedProfileId } | Select-Object -First 1)
    if ($selectedProfile.Count -eq 0) {
        throw 'No selected Codex account is saved.'
    }

    $codexPath = (Get-Content -LiteralPath $realCodexPathFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($codexPath) -or -not (Test-Path -LiteralPath $codexPath)) {
        throw 'The original Codex CLI executable is missing. Run the account switcher again to repair the command shim.'
    }

    $env:CODEX_HOME = [string]$selectedProfile[0].home
    & $codexPath @args
    if ($null -ne $LASTEXITCODE) {
        exit $LASTEXITCODE
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine("Codex account switcher: $($_.Exception.Message)")
    exit 1
}
