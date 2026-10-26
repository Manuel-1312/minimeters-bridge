<#  Removes the minimeters-bridge background task and its private files. No admin needed. #>
[CmdletBinding()]
param(
    [string]$TaskName   = 'MiniMetersBridge',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'MiniMetersBridge')
)
$ErrorActionPreference = 'Stop'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed the '$TaskName' background service."
} else {
    Write-Host "'$TaskName' is not installed."
}

# stop this install's bridge (anchored to its own venv / path, not any file named bridge.py)
# so nothing holds port 8985 or the files, then wait for the OS to release the handles.
$venvDir = Join-Path $InstallDir '.venv'
$bridge  = Join-Path $InstallDir 'bridge.py'
$pids = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($venvDir, [StringComparison]::OrdinalIgnoreCase)) -or
        ($_.CommandLine    -and $_.CommandLine.IndexOf($bridge, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | ForEach-Object { $_.ProcessId }
foreach ($procId in $pids) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
if ($pids) { Wait-Process -Id $pids -Timeout 10 -ErrorAction SilentlyContinue }

if (Test-Path $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {           # a native DLL may still be releasing - retry once
        Start-Sleep -Milliseconds 500
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path $InstallDir) {
        Write-Warning "Could not fully remove $InstallDir (a file may still be in use). Delete it manually."
    } else {
        Write-Host "Removed the private environment and files ($InstallDir)."
    }
}

Write-Host "Done. Python 3.12 was left in place in case other apps use it."
