# rebuild.ps1 – Fully stops, rebuilds, and restarts the entire ecommerce stack.
#
# Usage:
#   .\rebuild.ps1                  # Stop, rebuild everything (no-cache), start
#   .\rebuild.ps1 -SkipTests       # Skip Maven tests (faster)
#   .\rebuild.ps1 -KeepData        # Preserve named volumes (database data)
#   .\rebuild.ps1 -NoUp            # Build images but do not start containers
#
# This is the canonical "I changed code and want to see it running" script.
# It guarantees fresh JARs inside the Docker images by rebuilding in one pass.

param(
    [switch]$SkipTests,
    [switch]$KeepData,
    [switch]$NoUp
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Ecommerce Platform - Full Rebuild        " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Skip tests : $(if ($SkipTests) { 'Yes' } else { 'No' })"
Write-Host "Keep data  : $(if ($KeepData) { 'Yes (volumes preserved)' } else { 'No (volumes removed)' })"
Write-Host "Start stack: $(if ($NoUp) { 'No (-NoUp)' } else { 'Yes' })"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ─── Step 1: Stop containers ─────────────────────────────────────────────────
Write-Host "[1/4] Stopping running containers..." -ForegroundColor Yellow
Push-Location $scriptDir
if ($KeepData) {
    & docker compose down --remove-orphans
} else {
    # Remove named volumes so databases start fresh (useful when schema changes)
    & docker compose down --remove-orphans --volumes
}
Pop-Location
Write-Host ""

# ─── Step 2: Maven builds ────────────────────────────────────────────────────
Write-Host "[2/4] Building Java services (Maven)..." -ForegroundColor Yellow
$buildArgs = @('-NoDocker')  # We handle Docker ourselves below (with -NoCache)
if ($SkipTests) { $buildArgs += '-SkipTests' }
& "$scriptDir\build-all.ps1" @buildArgs
Write-Host ""

# ─── Step 3: Docker image rebuild (always --no-cache here for full freshness) ─
Write-Host "[3/4] Rebuilding Docker images (no-cache)..." -ForegroundColor Yellow
Push-Location $scriptDir
& docker compose build --no-cache
Pop-Location
Write-Host ""

# ─── Step 4: Start ───────────────────────────────────────────────────────────
if ($NoUp) {
    Write-Host "[4/4] Skipping container start (-NoUp was set)." -ForegroundColor Yellow
} else {
    Write-Host "[4/4] Starting the stack..." -ForegroundColor Yellow
    Push-Location $scriptDir
    & docker compose up -d
    Pop-Location
    Write-Host ""
    Write-Host "Rebuild complete! Stack is starting up." -ForegroundColor Green
    Write-Host "Tip: run  docker compose logs -f  to follow logs." -ForegroundColor Green
}
