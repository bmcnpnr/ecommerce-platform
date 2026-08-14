param(
    [switch]$SkipTests,
    [switch]$NoDocker,  # Maven only; skip Docker image rebuild
    [switch]$NoCache    # Pass --no-cache to docker compose build
)

$JAVA_HOME = 'C:\Program Files\Java\jdk-25.0.2'
$MAVEN_HOME = 'C:\Users\burak\apache-maven-3.9.14'
$MVN = "$MAVEN_HOME\bin\mvn.cmd"

$env:JAVA_HOME = $JAVA_HOME
$env:PATH = "$MAVEN_HOME\bin;$JAVA_HOME\bin;$env:PATH"

$mvnArgs = if ($SkipTests) { @('clean', 'install', '-Dmaven.test.skip=true') } else { @('clean', 'install') }

$services = @(
    'ecommerce-service-discovery',
    'ecommerce-api-gateway',
    'ecommerce-user-service',
    'ecommerce-product-service',
    'ecommerce-catalog-service',
    'ecommerce-order-service',
    'ecommerce-payment-service',
    'ecommerce-shipping-service',
    'ecommerce-review-service',
    'ecommerce-notification-service'
)

# Script lives in ecommerce-platform/; sibling repos are one level up.
$scriptDir = $PSScriptRoot
$ROOT = Split-Path -Parent $scriptDir

$results = [ordered]@{}
$startTime = Get-Date

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Ecommerce Platform - Build All Services  " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Java  : $JAVA_HOME"
Write-Host "Maven : $MAVEN_HOME"
Write-Host "Tests : $(if ($SkipTests) { 'Skipped' } else { 'Enabled' })"
Write-Host "Docker: $(if ($NoDocker) { 'Skipped (-NoDocker)' } else { 'Rebuild images after Maven' })"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ─── Maven builds ────────────────────────────────────────────────────────────
foreach ($svc in $services) {
    $path = Join-Path $ROOT $svc
    Write-Host "---------- $svc ----------" -ForegroundColor Yellow
    Push-Location $path
    $svcStart = Get-Date
    & $MVN @mvnArgs 2>&1 | Where-Object {
        $_ -match '(BUILD SUCCESS|BUILD FAILURE|\[ERROR\]|\[WARNING\].*deprecated|Tests run|INFO.*Building)'
    }
    $elapsed = [math]::Round(((Get-Date) - $svcStart).TotalSeconds, 1)
    if ($LASTEXITCODE -eq 0) {
        Write-Host "PASSED: $svc (${elapsed}s)" -ForegroundColor Green
        $results[$svc] = "SUCCESS"
    } else {
        Write-Host "FAILED: $svc (${elapsed}s)" -ForegroundColor Red
        $results[$svc] = "FAILED"
    }
    Pop-Location
    Write-Host ""
}

$totalElapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)
$successCount = ($results.Values | Where-Object { $_ -eq 'SUCCESS' }).Count
$failCount    = ($results.Values | Where-Object { $_ -eq 'FAILED'  }).Count

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   BUILD SUMMARY  (${totalElapsed}s total)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
foreach ($svc in $services) {
    $color = if ($results[$svc] -eq 'SUCCESS') { 'Green' } else { 'Red' }
    $icon  = if ($results[$svc] -eq 'SUCCESS') { '[OK]  ' } else { '[FAIL]' }
    Write-Host "$icon $svc" -ForegroundColor $color
}
Write-Host "--------------------------------------------" -ForegroundColor Cyan
Write-Host "$successCount passed, $failCount failed" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
Write-Host "============================================" -ForegroundColor Cyan

# ─── Docker image rebuild ────────────────────────────────────────────────────
# This step copies the freshly built JARs into Docker images so that
# 'docker compose up' actually runs the new code. Without this step,
# Docker reuses cached images that contain the old JARs.
if (-not $NoDocker) {
    if ($failCount -gt 0) {
        Write-Host ""
        Write-Host "Skipping Docker build: $failCount Maven build(s) failed." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host "   Rebuilding Docker images               " -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        $dockerArgs = @('compose', 'build')
        if ($NoCache) { $dockerArgs += '--no-cache' }
        Push-Location $scriptDir
        & docker @dockerArgs
        Pop-Location
        Write-Host ""
        Write-Host "Docker images rebuilt successfully." -ForegroundColor Green
        Write-Host "Run 'docker compose up -d' to start the stack." -ForegroundColor Green
    }
}

exit $failCount
