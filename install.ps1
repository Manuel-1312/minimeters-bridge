<#
    Installs minimeters-bridge as a background Scheduled Task that starts at logon.
    Run from anywhere:  powershell -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'MiniMetersBridge',
    [switch]$SkipDeps
)

$ErrorActionPreference = 'Stop'
$here   = $PSScriptRoot
$bridge = Join-Path $here 'bridge.py'
if (-not (Test-Path $bridge)) { throw "bridge.py not found next to install.ps1 ($here)" }

# --- locate pythonw.exe (prefer the 3.12 the wheels target) ---
function Resolve-Pythonw {
    $q = 'import os,sys; print(os.path.join(os.path.dirname(sys.executable),"pythonw.exe"))'
    foreach ($cmd in @(@('py','-3.12'), @('py','-3'), @('python'))) {
        $exe, $pre = $cmd[0], $cmd[1..($cmd.Count-1)]
        if (Get-Command $exe -ErrorAction SilentlyContinue) {
            try {
                $path = (& $exe @pre -c $q 2>$null).Trim()
                if ($path -and (Test-Path $path)) { return $path }
            } catch {}
        }
    }
    throw 'Could not find a Python 3.x install (tried the py launcher and python on PATH).'
}
$pythonw = Resolve-Pythonw
Write-Host "Python:  $pythonw"

# --- dependencies ---
if (-not $SkipDeps) {
    $python = $pythonw -replace 'pythonw\.exe$','python.exe'
    Write-Host 'Installing dependencies...'
    & $python -m pip install -r (Join-Path $here 'requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw "pip install failed ($LASTEXITCODE)" }
}

# --- (re)register the task ---
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$bridge`"" -WorkingDirectory $here
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Delay = 'PT30S'   # let the audio device settle before opening loopback
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 5

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Limited -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed and started '$TaskName'. It will launch automatically at logon."
Write-Host "Logs: $(Join-Path $here 'bridge.log')   WebSocket: ws://127.0.0.1:8985"
