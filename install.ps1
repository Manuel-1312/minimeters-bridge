<#
    minimeters-bridge installer (Windows PowerShell 5.1+ compatible).

    Normally you just double-click "Install MiniMeters Bridge.bat"; this script does the work:
      - finds (or installs, per-user, no admin) CPython 3.12
      - builds a private virtual environment and installs the audio libraries
      - registers a per-user Scheduled Task that runs the bridge at logon
      - relocates itself to %LOCALAPPDATA%\MiniMetersBridge so deleting the download is safe

    Run manually:  powershell -ExecutionPolicy Bypass -File install.ps1
#>
[CmdletBinding()]
param(
    [string]$TaskName   = 'MiniMetersBridge',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'MiniMetersBridge'),
    [switch]$SkipDeps
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  $m" -ForegroundColor Green }
function Fail($what, $fix) {
    Write-Host ''
    Write-Host "X  $what" -ForegroundColor Red
    if ($fix) { Write-Host "   $fix" -ForegroundColor Yellow }
    exit 1
}

# --- true only if $exe is REALLY CPython 3.12. Never trusts the name. ---
# The probe deliberately uses NO spaces and NO quotes: Windows PowerShell 5.1 mangles
# native-command arguments that contain either, so we signal the result via the exit code.
function Test-Is312($exe) {
    if (-not $exe) { return $false }
    try {
        & $exe -c 'import sys;sys.exit(sys.version_info[:2]!=(3,12))' 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Get-Python312 {
    # 1. the py launcher, explicit version
    if (Get-Command py -ErrorAction SilentlyContinue) {
        try {
            $exe = (& py -3.12 -c 'import sys;print(sys.executable)' 2>$null)
            if ($exe) { $exe = $exe.Trim() }
            if (Test-Is312 $exe) { return $exe }
        } catch {}
        # 2. parse the launcher's version list (handles both -0p and --list output shapes)
        foreach ($listArg in @('-0p', '--list-paths', '--list')) {
            try {
                $lines = & py $listArg 2>$null
                foreach ($ln in $lines) {
                    if ($ln -match '3\.12') {
                        $m = [regex]::Match([string]$ln, '([A-Za-z]:\\[^\r\n]*python\.exe)')
                        if ($m.Success -and (Test-Is312 $m.Groups[1].Value)) { return $m.Groups[1].Value }
                    }
                }
            } catch {}
        }
    }
    # 3. the deterministic per-user install path winget uses
    $fixed = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if ((Test-Path $fixed) -and (Test-Is312 $fixed)) { return $fixed }
    # 4. a bare "python" on PATH, but never the Microsoft Store alias stub
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and ($cmd.Source -notmatch 'WindowsApps') -and (Test-Is312 $cmd.Source)) {
        return $cmd.Source
    }
    return $null
}

function Get-Port8985Owner {
    try {
        $c = Get-NetTCPConnection -LocalPort 8985 -State Listen -ErrorAction SilentlyContinue
        if ($c) { return ($c.OwningProcess | Select-Object -First 1) }
    } catch {
        $line = netstat -ano | Select-String ':8985\s' | Select-String 'LISTENING' | Select-Object -First 1
        if ($line) { $p = -split $line.ToString(); return [int]$p[-1] }
    }
    return $null
}

try {
    # (1) clear Mark-of-the-Web on the freshly unzipped files
    try { Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Force | Unblock-File -ErrorAction SilentlyContinue } catch {}

    # (2) relocate into %LOCALAPPDATA% so a deleted download can't break the task
    $srcRoot = (Resolve-Path $PSScriptRoot).Path.TrimEnd('\')
    $dstRoot = ([IO.Path]::GetFullPath($InstallDir)).TrimEnd('\')
    if ($srcRoot -ine $dstRoot) {
        Step "Copying files to $dstRoot"
        if (-not (Test-Path $dstRoot)) { New-Item -ItemType Directory -Path $dstRoot -Force | Out-Null }
        Get-ChildItem -LiteralPath $srcRoot -Force |
            Where-Object { @('.git', '.venv', '__pycache__') -notcontains $_.Name -and $_.Extension -ne '.log' } |
            Copy-Item -Destination $dstRoot -Recurse -Force
        $here = $dstRoot
    } else {
        $here = $srcRoot
    }
    $bridge = Join-Path $here 'bridge.py'
    if (-not (Test-Path $bridge)) { Fail "bridge.py is missing next to the installer." "Re-download the project as a ZIP and try again." }

    # (3)/(4) ensure a real Python 3.12 (install per-user via winget if absent)
    Step 'Checking for Python 3.12'
    $py = Get-Python312
    if (-not $py) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Step 'Installing Python 3.12 for your user (no admin needed)'
            & winget install --id Python.Python.3.12 -e --scope user --silent --accept-package-agreements --accept-source-agreements
            # PATH/registry are stale in this process; re-detect, favouring the fixed install path
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
            $py = Get-Python312
            if (-not $py) {
                $fixed = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
                if ((Test-Path $fixed) -and (Test-Is312 $fixed)) { $py = $fixed }
            }
            if (-not $py) {
                Write-Host ''
                Write-Host 'Python 3.12 is installed. Close this window and run the installer once more to finish.' -ForegroundColor Yellow
                exit 1   # not finished yet - a fresh process will pick up the new Python
            }
        } else {
            Fail 'Could not install Python 3.12 automatically (winget is not available).' `
                 'Install Python 3.12 (64-bit) from https://www.python.org/downloads/release/python-3129/ - tick "Add python.exe to PATH" and "py launcher" - then run this again.'
        }
    }
    Ok "Using $py"

    # (5) build an isolated virtual environment
    $venvDir = Join-Path $here '.venv'
    $venvPy  = Join-Path $venvDir 'Scripts\python.exe'
    $venvPyw = Join-Path $venvDir 'Scripts\pythonw.exe'
    if ((Test-Path $venvDir) -and (-not (Test-Path $venvPyw))) {
        Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $venvPyw)) {
        Step 'Building a private environment'
        & $py -m venv $venvDir
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPyw)) { Fail 'Could not create the virtual environment.' 'Make sure Python 3.12 installed correctly, then run this again.' }
    }

    # (6) install dependencies (binary wheels only - a wrong interpreter can never trigger a source build)
    if (-not $SkipDeps) {
        Step 'Installing the audio libraries'
        & $venvPy -m pip install --disable-pip-version-check --no-input --upgrade pip | Out-Null
        & $venvPy -m pip install --disable-pip-version-check --no-input --only-binary=:all: -r (Join-Path $here 'requirements.txt')
        if ($LASTEXITCODE -ne 0) { Fail 'The audio libraries did not install cleanly.' 'This usually means no Python 3.12 wheel exists for your platform (for example ARM64). See the pip output above.' }
        & $venvPy -c 'import pyaudiowpatch,numpy,scipy,websockets,pycaw,comtypes' 2>$null
        if ($LASTEXITCODE -ne 0) { Fail 'A required library failed to import.' 'Run the installer again; if it persists, check bridge.log.' }
    }

    # (7) (re)register the background task, idempotently
    Step 'Registering the background service'
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    # free the port / file locks from a previous instance of THIS bridge (not some
    # unrelated pythonw the user happens to run that also loads a file named bridge.py)
    Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($venvDir, [StringComparison]::OrdinalIgnoreCase)) -or
            ($_.CommandLine    -and $_.CommandLine.IndexOf($bridge, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    $action  = New-ScheduledTaskAction -Execute $venvPyw -Argument ("`"$bridge`"") -WorkingDirectory $here
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $trigger.Delay = 'PT30S'   # let the audio device settle before opening the loopback
    $sid       = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 5
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null

    # (8) start it and verify honestly
    Step 'Starting the bridge'
    Start-ScheduledTask -TaskName $TaskName
    $live = $false
    for ($i = 0; $i -lt 9; $i++) {
        Start-Sleep -Seconds 2
        $owner = Get-Port8985Owner
        if ($owner) {
            # only count it as ours if the listener is our venv pythonw running our bridge.py
            $op = Get-CimInstance Win32_Process -Filter "ProcessId=$owner" -ErrorAction SilentlyContinue
            if ($op) {
                $byExe = $op.ExecutablePath -and $op.ExecutablePath.StartsWith($venvDir, [StringComparison]::OrdinalIgnoreCase)
                $byCmd = $op.CommandLine   -and $op.CommandLine.IndexOf($bridge, [StringComparison]::OrdinalIgnoreCase) -ge 0
                if ($byExe -or $byCmd) { $live = $true; break }
            }
        }
    }

    Write-Host ''
    if ($live) {
        Write-Host "MiniMeters bridge is running on ws://127.0.0.1:8985" -ForegroundColor Green
        Write-Host "It will start automatically about 30 seconds after each logon."
    } else {
        Write-Host "The service is registered but has not opened ws://127.0.0.1:8985 yet." -ForegroundColor Yellow
        Write-Host "It retries automatically ~30 s after logon. If port 8985 is used by another app," -ForegroundColor Yellow
        Write-Host "close that app (or change PORT in bridge.py and the visualizer)." -ForegroundColor Yellow
        $log = Join-Path $here 'bridge.log'
        if (Test-Path $log) {
            Write-Host ''
            Write-Host "Last lines of bridge.log:"
            Get-Content -LiteralPath $log -Tail 15 | ForEach-Object { Write-Host "  $_" }
        }
    }
    Write-Host ''
    Write-Host "Files:  $here"
    Write-Host "Log:    $(Join-Path $here 'bridge.log')"
    Write-Host "Next:   set up the Spotify side with visualizer\README.md"
}
catch {
    Fail $_.Exception.Message 'See bridge.log under %LOCALAPPDATA%\MiniMetersBridge for details.'
}
