<#
.SYNOPSIS
    Boots RTSDemo in a standalone VertexForge Runtime.exe and reports what the log says.

.DESCRIPTION
    The smoke test for the dogfood loop (VK-1298): the game *is* the system test, so the
    cheapest useful signal is "does the shipped Runtime open this project without dying".

    Runtime.exe takes the .vfproj as argv[1] (VFEngine/runtime/run/Main.cpp) and writes
    logs/Runtime.log + crashes/*.dmp RELATIVE TO ITS WORKING DIRECTORY (util::initLogFile
    and util::installCrashHandler both use relative paths), so this script runs it with the
    project directory as CWD. That is why the log and crash dumps land in C:\matan\RTSDemo
    and not next to the exe.

    Until Slice 2 lands App::quit(exitCode), Runtime.exe has no way to stop itself: the
    timeout IS the normal exit path and reports 124. Judge the run by the log counters
    (errors / notCompiled / crashes), not by the exit code.

    The log is read as a byte-range delta from a pre-launch mark so a long-lived log file
    does not drown the run in history. spdlog rotates at 5 MB; if the file shrank we fall
    back to reading the whole thing.

.EXAMPLE
    .\tools\run_smoke.ps1
    .\tools\run_smoke.ps1 -TimeoutSec 30
#>
[CmdletBinding()]
param(
    [string] $Exe        = 'C:\matan\VertexForge\bin\Runtime\Development\x64\Runtime.exe',
    [string] $Proj       = 'C:\matan\RTSDemo\RTSDemo.vfproj',
    [int]    $TimeoutSec = 90
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectDir = 'C:\matan\RTSDemo'
$LogPath    = Join-Path $ProjectDir 'logs\Runtime.log'
$CrashDir   = Join-Path $ProjectDir 'crashes'

# Read a file that another process may still hold open for writing. spdlog's rotating sink
# keeps logs/Runtime.log open for the whole session, so a plain Get-Content can fail with a
# sharing violation on the timeout path.
function Read-SharedText {
    param([string] $Path, [long] $Offset = 0)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        if ($Offset -gt 0 -and $Offset -le $stream.Length) {
            [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        }
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } catch {
        Write-Warning ("could not read {0}: {1}" -f $Path, $_.Exception.Message)
        return ''
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-FileLength {
    param([string] $Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Item -LiteralPath $Path).Length }
    return 0
}

# ---------------------------------------------------------------- preconditions
if (-not (Test-Path -LiteralPath $Exe)) {
    Write-Host "FAIL: Runtime.exe not found at $Exe"
    Write-Host "      Build the Runtime project (Development|x64) first."
    exit 2
}
if (-not (Test-Path -LiteralPath $Proj)) {
    Write-Host "FAIL: project not found at $Proj"
    exit 2
}

$Stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutDir = Join-Path $ProjectDir ("tools\out\" + $Stamp)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# ---------------------------------------------------------------- pre-launch marks
$logMark = Get-FileLength $LogPath

$crashBefore = @()
if (Test-Path -LiteralPath $CrashDir) {
    $crashBefore = @(Get-ChildItem -LiteralPath $CrashDir -File | Select-Object -ExpandProperty Name)
}

Write-Host "run_smoke: exe=$Exe"
Write-Host "run_smoke: proj=$Proj  cwd=$ProjectDir  timeout=${TimeoutSec}s"
Write-Host "run_smoke: log mark=$logMark bytes, crashes before=$($crashBefore.Count)"

# ---------------------------------------------------------------- launch
$stdoutPath = Join-Path $OutDir 'Runtime.stdout.txt'
$stderrPath = Join-Path $OutDir 'Runtime.stderr.txt'

$startedUtc = Get-Date
$proc = Start-Process -FilePath $Exe `
                      -ArgumentList $Proj `
                      -WorkingDirectory $ProjectDir `
                      -PassThru `
                      -RedirectStandardOutput $stdoutPath `
                      -RedirectStandardError  $stderrPath

$timedOut = $false
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    Write-Host "run_smoke: timeout after ${TimeoutSec}s -- killing pid $($proc.Id)"
    try { $proc.Kill() } catch { Write-Warning "kill failed: $($_.Exception.Message)" }
    # Give the OS a bounded window to release the log file handle before we read it.
    [void]$proc.WaitForExit(5000)
}

$exitCode = 124
if (-not $timedOut) { $exitCode = $proc.ExitCode }
$elapsed = [int]((Get-Date) - $startedUtc).TotalSeconds

# ---------------------------------------------------------------- log delta
$logNow = Get-FileLength $LogPath
$offset = $logMark
if ($logNow -lt $logMark) {
    # spdlog rotated (or the log was cleared) -- the mark is meaningless, take everything.
    $offset = 0
}
$logText  = Read-SharedText -Path $LogPath -Offset $offset
$logLines = @()
if ($logText.Length -gt 0) {
    $logLines = @($logText -split "`r?`n" | Where-Object { $_.Length -gt 0 })
}

$errorLines       = @($logLines | Where-Object { $_ -match '\[error\]' })
$notCompiledLines = @($logLines | Where-Object { $_ -match 'Scripts not compiled' })
$notFoundLines    = @($logLines | Where-Object { $_ -match 'not found' })

$crashAfter = @()
if (Test-Path -LiteralPath $CrashDir) {
    $crashAfter = @(Get-ChildItem -LiteralPath $CrashDir -File | Select-Object -ExpandProperty Name)
}
$newCrashes = @($crashAfter | Where-Object { $crashBefore -notcontains $_ })

# ---------------------------------------------------------------- artifacts
$tailPath = Join-Path $OutDir 'Runtime.tail.log'
Set-Content -LiteralPath $tailPath -Value $logLines -Encoding UTF8

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("stamp        : $Stamp")
$summary.Add("exe          : $Exe")
$summary.Add("proj         : $Proj")
$summary.Add("timeoutSec   : $TimeoutSec")
$summary.Add("timedOut     : $timedOut")
$summary.Add("exitCode     : $exitCode")
$summary.Add("elapsedSec   : $elapsed")
$summary.Add("newLogLines  : $($logLines.Count)")
$summary.Add("errors       : $($errorLines.Count)")
$summary.Add("notCompiled  : $($notCompiledLines.Count)")
$summary.Add("notFound     : $($notFoundLines.Count)")
$summary.Add("newCrashes   : $($newCrashes.Count)")
if ($newCrashes.Count -gt 0) {
    $summary.Add("crashFiles   : $($newCrashes -join ', ')")
}

$summary.Add("")
$summary.Add("-- distinct [error] messages (top 10) --")
# Strip the leading timestamp so identical errors from different frames collapse.
$distinctErrors = @($errorLines |
    ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ ', '' } |
    Group-Object |
    Sort-Object -Property Count -Descending |
    Select-Object -First 10)
foreach ($g in $distinctErrors) { $summary.Add(("{0,5}x {1}" -f $g.Count, $g.Name)) }

$summary.Add("")
$summary.Add("-- distinct 'not found' messages (top 10) --")
$distinctNotFound = @($notFoundLines |
    ForEach-Object { $_ -replace '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ ', '' } |
    Group-Object |
    Sort-Object -Property Count -Descending |
    Select-Object -First 10)
foreach ($g in $distinctNotFound) { $summary.Add(("{0,5}x {1}" -f $g.Count, $g.Name)) }

$summaryPath = Join-Path $OutDir 'summary.txt'
Set-Content -LiteralPath $summaryPath -Value $summary -Encoding UTF8

# ---------------------------------------------------------------- report
Write-Host ""
foreach ($line in $summary) { Write-Host $line }
Write-Host ""
Write-Host "artifacts: $OutDir"
Write-Host "exit=$exitCode errors=$($errorLines.Count) notCompiled=$($notCompiledLines.Count) crashes=$($newCrashes.Count)"

# A clean smoke run today is: process reached the timeout (it has no way to quit yet),
# nothing crashed, and the script VM actually compiled. Anything else is worth a look.
if ($newCrashes.Count -gt 0) { exit 1 }
if ($notCompiledLines.Count -gt 0) { exit 1 }
if ($timedOut) { exit 0 }
exit $exitCode
