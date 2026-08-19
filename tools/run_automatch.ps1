<#
.SYNOPSIS
  Runs the RTSDemo automated match (AutomatedMatchController) in the standalone Runtime and
  turns its log protocol into a pass/fail verdict.

.DESCRIPTION
  1. Writes C:\matan\RTSDemo\config.json {"autoMatch":true, ...} (Config::getBool("autoMatch") is
     the controller's gate; the file is restored afterwards).
  2. Launches Runtime.exe with the .vfproj, CWD = project dir (logs/Runtime.log, crashes/ land there).
  3. Waits for App::quit(exitCode) or the timeout, then parses the NEW log lines for the
     [Script] protocol emitted by AutomatedMatchController:
        PHASE,<name>,<t>
        ASSERT,<name>,PASS|FAIL,<detail>
        STAT,<t>,<fps>,<cpuMs>,<gpuMs>,<drawCalls>,<pUnits>,<eUnits>,<pBuildings>,<eBuildings>,<gold>
        MATCH,END,<WIN|LOSE|TIMEOUT>,<t>
        DEATH,... / WAVE,... / COROUTINE,tick,<n>
  4. Verdict = exit code 0 AND no ASSERT FAIL AND MATCH,END present AND no new crash dump.
     Writes tools\out\<stamp>\{Runtime.tail.log, asserts.txt, stats.csv, summary.txt}.

.PARAMETER Scenario  assault (default) | defend | soak   -> config.json "autoMatchScenario"
.PARAMETER TimeoutSec Wall-clock kill timeout (default 420). "autoMatchTimeoutSec" is passed as TimeoutSec-60.

  Exit code: 0 = pass, 1 = fail, 124 = runtime timeout (killed), 2 = launch problem.
#>
param(
    [string]$Exe = "C:\matan\VertexForge\bin\Runtime\Development\x64\Runtime.exe",
    [string]$Proj = "C:\matan\RTSDemo\RTSDemo.vfproj",
    [string]$Scenario = "assault",
    [int]$TimeoutSec = 420
)

$ErrorActionPreference = "Continue"
$projDir = Split-Path -Parent $Proj
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outDir = Join-Path $projDir ("tools\out\automatch_" + $stamp)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not (Test-Path $Exe)) { Write-Host "Runtime not found: $Exe"; exit 2 }
if (-not (Test-Path $Proj)) { Write-Host "Project not found: $Proj"; exit 2 }

# --- config.json gate (restore afterwards) --------------------------------------------------
$configPath = Join-Path $projDir "config.json"
$configBackup = $null
if (Test-Path $configPath) { $configBackup = Get-Content $configPath -Raw -Encoding UTF8 }
$gameTimeout = [Math]::Max(60, $TimeoutSec - 60)
$config = @{}
if ($configBackup) {
    try { $parsed = $configBackup | ConvertFrom-Json; foreach ($p in $parsed.PSObject.Properties) { $config[$p.Name] = $p.Value } } catch {}
}
$config["autoMatch"] = $true
$config["autoMatchScenario"] = $Scenario
$config["autoMatchTimeoutSec"] = $gameTimeout
($config | ConvertTo-Json -Compress) | Out-File -FilePath $configPath -Encoding utf8 -NoNewline

# --- capture log/crash state before launch --------------------------------------------------
$logPath = Join-Path $projDir "logs\Runtime.log"
$startLen = 0
if (Test-Path $logPath) { $startLen = (Get-Item $logPath).Length }
$crashDir = Join-Path $projDir "crashes"
$crashesBefore = @()
if (Test-Path $crashDir) { $crashesBefore = @(Get-ChildItem $crashDir | ForEach-Object { $_.Name }) }

# --- launch ---------------------------------------------------------------------------------
Write-Host ("[automatch] scenario={0} timeout={1}s exe={2}" -f $Scenario, $TimeoutSec, $Exe)
$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $Exe -ArgumentList ('"' + $Proj + '"') -WorkingDirectory $projDir -PassThru
$exitCode = -1
if ($proc.WaitForExit($TimeoutSec * 1000)) {
    $exitCode = $proc.ExitCode
} else {
    Write-Host "[automatch] TIMEOUT after $TimeoutSec s -> killing"
    try { $proc.Kill() } catch {}
    $exitCode = 124
}
$sw.Stop()

# --- restore config.json --------------------------------------------------------------------
if ($null -ne $configBackup) { $configBackup | Out-File -FilePath $configPath -Encoding utf8 -NoNewline }
else { Remove-Item $configPath -Force -ErrorAction SilentlyContinue }

# --- read the new log tail ------------------------------------------------------------------
$lines = @()
if (Test-Path $logPath) {
    $fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite')
    try {
        # Rotation guard: if the file shrank, read it whole.
        if ($fs.Length -lt $startLen) { $startLen = 0 }
        $fs.Seek($startLen, 'Begin') | Out-Null
        $sr = New-Object IO.StreamReader($fs)
        $lines = ($sr.ReadToEnd() -split "`r?`n")
        $sr.Close()
    } finally { $fs.Dispose() }
}
$lines | Set-Content (Join-Path $outDir "Runtime.tail.log") -Encoding UTF8

# --- parse protocol -------------------------------------------------------------------------
$proto = @()
foreach ($l in $lines) {
    if ($l -match '\[Script\]\s+((?:ASSERT|STAT|PHASE|MATCH|DEATH|WAVE|COROUTINE),.*)$') { $proto += $Matches[1] }
}
$asserts = @($proto | Where-Object { $_ -like 'ASSERT,*' })
$fails   = @($asserts | Where-Object { $_ -match '^ASSERT,[^,]*,FAIL' })
$passes  = @($asserts | Where-Object { $_ -match '^ASSERT,[^,]*,PASS' })
$stats   = @($proto | Where-Object { $_ -like 'STAT,*' })
$phases  = @($proto | Where-Object { $_ -like 'PHASE,*' })
$matchEnd = @($proto | Where-Object { $_ -like 'MATCH,END,*' })
$deaths  = @($proto | Where-Object { $_ -like 'DEATH,*' })
$waves   = @($proto | Where-Object { $_ -like 'WAVE,*' })
$corout  = @($proto | Where-Object { $_ -like 'COROUTINE,*' })
$errors  = @($lines | Where-Object { $_ -match '\[error\]' })
$crashesAfter = @()
if (Test-Path $crashDir) { $crashesAfter = @(Get-ChildItem $crashDir | Where-Object { $crashesBefore -notcontains $_.Name } | ForEach-Object { $_.Name }) }

$asserts | Set-Content (Join-Path $outDir "asserts.txt") -Encoding UTF8
("t,fps,cpuMs,gpuMs,drawCalls,pUnits,eUnits,pBuildings,eBuildings,gold") | Set-Content (Join-Path $outDir "stats.csv") -Encoding UTF8
$stats | ForEach-Object { $_.Substring(5) } | Add-Content (Join-Path $outDir "stats.csv") -Encoding UTF8
$phases + $matchEnd | Set-Content (Join-Path $outDir "phases.txt") -Encoding UTF8

# top unique error messages (strip timestamp prefix)
$errKeys = @{}
foreach ($e in $errors) {
    $msg = ($e -replace '^\S+\s+\S+\s+\[error\]\s*', '')
    if ($msg.Length -gt 140) { $msg = $msg.Substring(0, 140) }
    if ($errKeys.ContainsKey($msg)) { $errKeys[$msg]++ } else { $errKeys[$msg] = 1 }
}
$topErrors = $errKeys.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10

# --- verdict --------------------------------------------------------------------------------
$verdict = 0
$reasons = @()
if ($exitCode -ne 0)        { $verdict = 1; $reasons += "exit=$exitCode" }
if ($fails.Count -gt 0)     { $verdict = 1; $reasons += ("assertFails=" + $fails.Count) }
if ($matchEnd.Count -eq 0)  { $verdict = 1; $reasons += "no MATCH,END" }
if ($crashesAfter.Count -gt 0) { $verdict = 1; $reasons += ("crashes=" + $crashesAfter.Count) }
if ($exitCode -eq 124)      { $verdict = 124 }

$summary = @()
$summary += ("scenario={0} wallSec={1:N0} exit={2} verdict={3} {4}" -f $Scenario, $sw.Elapsed.TotalSeconds, $exitCode, $verdict, ($reasons -join ' '))
$summary += ("asserts: pass={0} fail={1} | phases={2} | statRows={3} | deaths={4} waves={5} coroutineTicks={6}" -f $passes.Count, $fails.Count, $phases.Count, $stats.Count, $deaths.Count, $waves.Count, $corout.Count)
$summary += ("matchEnd: {0}" -f (($matchEnd | Select-Object -Last 1) -join ''))
$summary += ("errors={0} newCrashDumps={1}" -f $errors.Count, $crashesAfter.Count)
$summary += "--- ASSERT FAILs ---"
$summary += $fails
$summary += "--- top errors ---"
foreach ($te in $topErrors) { $summary += ("{0,5}  {1}" -f $te.Value, $te.Key) }
$summary | Set-Content (Join-Path $outDir "summary.txt") -Encoding UTF8
$summary | ForEach-Object { Write-Host $_ }
Write-Host "[automatch] artifacts: $outDir"
exit $verdict
