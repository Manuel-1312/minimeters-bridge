<#
    Remote bootstrap for the one-liner:
        irm https://raw.githubusercontent.com/Manuel-1312/minimeters-bridge/main/get.ps1 | iex
    Downloads the repo, unblocks it and runs install.ps1 (which self-relocates to %LOCALAPPDATA%).
#>
$ErrorActionPreference = 'Stop'
$zip   = Join-Path $env:TEMP 'minimeters-bridge.zip'
$stage = Join-Path $env:TEMP ('mmb-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Host 'Downloading MiniMeters Bridge...'
    Invoke-WebRequest -UseBasicParsing `
        -Uri 'https://github.com/Manuel-1312/minimeters-bridge/archive/refs/heads/main.zip' `
        -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $stage -Force
    $src = Get-ChildItem -LiteralPath $stage -Directory | Select-Object -First 1
    if (-not $src) { throw 'Downloaded archive was empty.' }
    Get-ChildItem -LiteralPath $src.FullName -Recurse -Force | Unblock-File -ErrorAction SilentlyContinue
    # run install.ps1 in a child process with a process-scoped policy bypass, so this works
    # even on a stock box whose execution policy is the default Restricted (mirrors the .bat)
    $installPs1 = Join-Path $src.FullName 'install.ps1'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPs1
    if ($LASTEXITCODE -ne 0) { throw "install.ps1 exited with code $LASTEXITCODE" }
}
catch {
    Write-Host ''
    Write-Host "X  Install did not finish: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '   Make sure you have an internet connection, then try again.' -ForegroundColor Yellow
    exit 1
}
finally {
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
