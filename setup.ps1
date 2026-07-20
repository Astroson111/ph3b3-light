#Requires -Version 5.1
<#
  setup.ps1 — Ph3b3-Light first-run wizard (Windows entry point).

  One command takes a fresh Windows PC from "just cloned" to "talking to Phoebe":
      powershell -ExecutionPolicy Bypass -File .\setup.ps1

  What it does, in order:
    1. Confirms WSL2 + an Ubuntu distro exist (tells you exactly how to get them).
    2. Ensures Ollama is running (your Windows install or one it sets up in WSL)
       and pulls the model.
    3. Runs setup.sh inside WSL: system libs, Python env, the Alba voice,
       a small Whisper model, and a .env with a freshly generated password.
    4. Starts the server, waits for /health, and opens the portal in your browser.

  Safe to re-run: every step is idempotent. It writes only inside this repo,
  ~/ph3b3_data, and .env — nothing else on your machine. Web access (egress)
  stays OFF by default; nothing phones home beyond the named installs below.
#>

$ErrorActionPreference = 'Stop'
$MODEL = 'hermes3'
$PORT  = 7331

function Say  ($m) { Write-Host "`n▶ $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "  ✓ $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  ($m, $next) {
  Write-Host "`n  ✗ $m" -ForegroundColor Red
  if ($next) { Write-Host "  → next: $next" -ForegroundColor Yellow }
  exit 1
}

Write-Host ""
Write-Host "  ┌───────────────────────────────────────────────┐" -ForegroundColor Magenta
Write-Host "  │      Ph3b3-Light — first-run setup wizard      │" -ForegroundColor Magenta
Write-Host "  └───────────────────────────────────────────────┘" -ForegroundColor Magenta

# ── 1. WSL2 + distro ─────────────────────────────────────────────────────────
Say "Checking for WSL2"
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Die "WSL is not installed." "open PowerShell as Administrator, run:  wsl --install  — then reboot and re-run this script."
}
# `wsl -l -v` output is UTF-16; -Encoding handled by the pipe. Look for a v2 distro.
$distros = (& wsl.exe -l -v) -replace "`0", "" 2>$null
if (-not ($distros -match '\s2\s*$' -or $distros -match '\s2\b')) {
  Warn "No WSL *version 2* distro detected. If Ubuntu is installed, run:  wsl --set-version Ubuntu 2"
}

# Which distro hosts this repo? If we're on a \\wsl.localhost\<distro>\ path, use it.
$here = $PSScriptRoot
$Distro   = $null
$LinuxPath = $null
if ($here -match '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\(.*)$') {
  $Distro    = $Matches[1]
  $LinuxPath = '/' + ($Matches[2] -replace '\\', '/')
  Ok "Repo lives in WSL distro '$Distro' at $LinuxPath"
} else {
  # Repo is on a Windows drive — translate to /mnt/... and use the default distro.
  $LinuxPath = (& wsl.exe wslpath -a "$here").Trim()
  $Distro    = ((& wsl.exe -l -q) -replace "`0", "" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
  Ok "Using default distro '$Distro'; repo at $LinuxPath"
  Warn "Running from a Windows drive (/mnt/...). It works but is slower — cloning inside WSL is recommended."
}
if (-not $Distro) { Die "Could not determine a WSL distro." "install Ubuntu:  wsl --install -d Ubuntu" }

# Helper: run a command in the repo dir inside WSL. Output streams to the console
# (so sudo can prompt and long installs show progress). Single quotes around the
# path are literal to PowerShell and safe for WSL home paths (no spaces/quotes).
function WslRun ($cmd) {
  $full = "cd '$LinuxPath' && $cmd"
  & wsl.exe -d $Distro -- bash -lc $full
  return $LASTEXITCODE
}
# Helper: capture trimmed stdout of a WSL command (for checks/creds).
function WslGet ($cmd) {
  $full = "cd '$LinuxPath' && $cmd"
  $out = & wsl.exe -d $Distro -- bash -lc $full 2>$null
  return ($out | Out-String).Trim()
}

if ((WslGet "test -f setup.sh && echo yes") -ne "yes") {
  Die "setup.sh not found next to this script inside WSL ($LinuxPath)." "clone the repo inside your WSL home (e.g. ~/ph3b3-light) and run setup.ps1 from there."
}

# ── 2. Ollama — local model runtime (Windows host OR WSL; we adapt to either) ─
# Everything reaches the daemon over http://localhost:11434, so we don't care
# where it runs: Ollama for Windows (via WSL2 mirrored networking) or Ollama
# installed inside WSL both work. We only install into WSL as a last resort.
Say "Ollama — local model runtime"
$winOllama = Get-Command ollama.exe -ErrorAction SilentlyContinue
$tagsHttp  = "curl -s -o /dev/null -w '%{http_code}' http://localhost:11434/api/tags"

if ((WslGet $tagsHttp) -ne "200") {
  if ($winOllama) {
    Warn "Ollama for Windows is installed but not answering — starting it…"
    Start-Process -WindowStyle Hidden -FilePath $winOllama.Source -ArgumentList 'serve'
  } elseif ((WslGet "command -v ollama >/dev/null 2>&1 && echo yes") -eq "yes") {
    Warn "Starting Ollama inside WSL…"
    WslRun "nohup ollama serve >/tmp/ollama.log 2>&1 & disown" | Out-Null
  } else {
    Warn "Ollama not found on Windows or in WSL — installing it inside WSL (ollama.com/install.sh)…"
    WslRun "curl -fsSL https://ollama.com/install.sh | sh" | Out-Null
    WslRun "nohup ollama serve >/tmp/ollama.log 2>&1 & disown" | Out-Null
  }
  $up = $false
  foreach ($i in 1..40) { Start-Sleep -Milliseconds 750; if ((WslGet $tagsHttp) -eq "200") { $up = $true; break } }
  if (-not $up) { Die "Ollama did not answer on port 11434." "start Ollama (open the Ollama app on Windows, or run 'ollama serve' in Ubuntu), then re-run setup.ps1" }
}
Ok "Ollama is reachable at localhost:11434"

# Is the model present? Ask the daemon over HTTP — independent of where it runs.
$modelRe = '"name"\s*:\s*"' + [regex]::Escape($MODEL)
if ((WslGet "curl -s http://localhost:11434/api/tags") -notmatch $modelRe) {
  Say "Pulling the '$MODEL' model — a few GB; this can take a while…"
  if ($winOllama) {
    & $winOllama.Source pull $MODEL
  } elseif ((WslGet "command -v ollama >/dev/null 2>&1 && echo yes") -eq "yes") {
    WslRun "ollama pull $MODEL"
  } else {
    # No CLI anywhere — pull through the daemon's own HTTP API ("" -> a literal ").
    WslRun "curl -s http://localhost:11434/api/pull -d '{""name"":""$MODEL""}' | tail -1"
  }
  if ((WslGet "curl -s http://localhost:11434/api/tags") -notmatch $modelRe) {
    Die "Model '$MODEL' still isn't available after the pull." "check disk space and your connection, then re-run setup.ps1 (it resumes)"
  }
}
Ok "Model '$MODEL' is available"

# ── 3. Linux-side setup (system libs, venv, Alba, Whisper, .env) ──────────────
Say "Running the Linux-side setup (setup.sh) — you may be asked for your WSL password (sudo)"
WslRun "bash setup.sh all"
if ($LASTEXITCODE -ne 0) { Die "setup.sh reported an error (see above)." "fix the reported item, then re-run setup.ps1 — completed steps are skipped" }

# ── 4. Start the server, wait for health, open the portal ────────────────────
$user = WslGet "grep -E '^PH3B3_USER=' .env | head -1 | cut -d= -f2-"
$pass = WslGet "grep -E '^PH3B3_PASSWORD=' .env | head -1 | cut -d= -f2-"
if (-not $pass) { Die "No password found in .env after setup." "run inside WSL:  ./setup.sh dotenv" }
# Honor a custom PH3B3_PORT from .env (defaults to 7331).
$envPort = WslGet "grep -E '^PH3B3_PORT=' .env | head -1 | cut -d= -f2-"
if ($envPort -match '^\d+$') { $PORT = [int]$envPort }

Say "Starting Phoebe…"
# Only start a new server if one isn't already answering on the port.
$already = $false
$b64chk  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:$pass"))
try {
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PORT/health" -Headers @{ Authorization = "Basic $b64chk" } -TimeoutSec 3 -UseBasicParsing
  if ($r.StatusCode -eq 200) { $already = $true }
} catch {}
if (-not $already) {
  # A process backgrounded inside a one-shot `wsl … &` is reaped the moment that
  # call returns (WSL tears down the session scope, so nohup/disown don't save it).
  # Instead launch a DETACHED Windows process that runs the server in the
  # foreground inside WSL: it outlives this script and keeps the WSL session — and
  # Phoebe — alive. Passed as one hand-quoted arg string so Start-Process doesn't
  # split the command on its spaces.
  $inner  = "cd '$LinuxPath' && exec .venv/bin/python agent/server.py >/tmp/ph3b3.log 2>&1"
  $wslArg = "-d $Distro -- bash -lc `"$inner`""
  Start-Process -WindowStyle Hidden -FilePath 'wsl.exe' -ArgumentList $wslArg | Out-Null
}

Say "Waiting for the server to answer on http://127.0.0.1:$PORT …"
$b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:$pass"))
$live = $false
foreach ($i in 1..40) {
  Start-Sleep -Milliseconds 750
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$PORT/health" -Headers @{ Authorization = "Basic $b64" } -TimeoutSec 3 -UseBasicParsing
    if ($r.StatusCode -eq 200) { $live = $true; break }
  } catch {}
}
if (-not $live) { Die "The server did not become healthy in time." "check the log inside WSL:  cat /tmp/ph3b3.log" }

$url = "http://127.0.0.1:$PORT/light/"
Ok "Phoebe is live."
Write-Host ""
Write-Host "  ┌─────────────────  YOU'RE IN  ─────────────────┐" -ForegroundColor Green
Write-Host ("  │  Portal:    {0,-33} │" -f $url)              -ForegroundColor Green
Write-Host ("  │  Username:  {0,-33} │" -f $user)             -ForegroundColor Green
Write-Host ("  │  Password:  {0,-33} │" -f $pass)             -ForegroundColor Green
Write-Host "  │  (browser will prompt for these once)         │" -ForegroundColor Green
Write-Host "  └───────────────────────────────────────────────┘" -ForegroundColor Green
Write-Host ""
Write-Host "  Web search is OFF by default — turn it on per-session from the Voice/Status panel." -ForegroundColor DarkGray
Write-Host "  To stop the server later:  wsl -d $Distro -- pkill -f agent/server.py" -ForegroundColor DarkGray

Start-Process $url
