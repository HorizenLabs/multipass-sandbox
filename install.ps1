# Multi Pass Sandbox (mps) — Windows Installer
# Adds bin/mps.ps1 to PATH and creates ~/.mps/ directory structure.

$ErrorActionPreference = "Stop"

$MpsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Info($msg) { Write-Host "[mps installer] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[mps installer] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[mps installer] $msg" -ForegroundColor Red }

# ---------- Preflight Checks ----------

Write-Info "Checking dependencies..."

$missing = $false
if (Get-Command "multipass" -ErrorAction SilentlyContinue) {
    Write-Info "  + multipass found"
} else {
    Write-Warn "  - multipass not found. Install from https://multipass.run/"
    $missing = $true
}

# jq is optional on Windows (ConvertFrom-Json is built-in)
if (Get-Command "jq" -ErrorAction SilentlyContinue) {
    Write-Info "  + jq found"
} else {
    Write-Info "  - jq not found (optional on Windows, using ConvertFrom-Json)"
}

if ($missing) {
    Write-Warn ""
    Write-Warn "Some dependencies are missing. Install them before using mps."
}

# ---------- Create Directory Structure ----------

Write-Info "Creating ~/.mps/ directory structure..."
$mpsHome = Join-Path $env:USERPROFILE ".mps"
New-Item -ItemType Directory -Force -Path (Join-Path $mpsHome "instances") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $mpsHome "cache/images") | Out-Null

# ---------- Add to PATH ----------

Write-Info "Adding $MpsRoot\bin to user PATH..."

$binPath = Join-Path $MpsRoot "bin"
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")

if ($currentPath -notlike "*$binPath*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$binPath", "User")
    Write-Info "Added to user PATH: $binPath"
    Write-Info "Restart your terminal for PATH changes to take effect."
} else {
    Write-Info "$binPath is already in PATH."
}

# ---------- Done ----------

Write-Info ""
Write-Info "Installation complete!"
Write-Info ""
Write-Info "Quick start:"
Write-Info "  mps up                  # Create and start a sandbox"
Write-Info "  mps shell               # Open shell in sandbox"
Write-Info "  mps list                # List sandboxes"
Write-Info "  mps --help              # Full usage"
