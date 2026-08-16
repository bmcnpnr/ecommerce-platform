# Builds the eleven application images and tags them ecommerce/<name>:local,
# which is what the manifests reference. PowerShell twin of build-images.sh.
#
# The Dockerfiles COPY a pre-built jar rather than compiling inside the image,
# so run ..\build-all.ps1 first. Skipping that step ships the previous jar and
# looks exactly like "my fix did not apply" — the pre-flight below fails loudly
# instead.
$ErrorActionPreference = 'Stop'

$K8sDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$PlatformDir = Split-Path -Parent $K8sDir
$Root        = Split-Path -Parent $PlatformDir

$Services = @(
    'service-discovery'
    'api-gateway'
    'user-service'
    'product-service'
    'catalog-service'
    'order-service'
    'payment-service'
    'shipping-service'
    'review-service'
    'notification-service'
)

# ─── Pre-flight: every jar must exist ────────────────────────────────────────
$missing = @()
foreach ($svc in $Services) {
    $jars = @(Get-ChildItem -Path "$Root\ecommerce-$svc\target\$svc-*.jar" -ErrorAction SilentlyContinue)
    if ($jars.Count -eq 0) { $missing += "ecommerce-$svc" }
}
if ($missing.Count -gt 0) {
    Write-Host "MISSING JARS:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Run ..\build-all.ps1 first - the Dockerfiles copy a pre-built jar"
    Write-Host "and cannot compile it themselves."
    exit 1
}

# ─── Build ───────────────────────────────────────────────────────────────────
# -p pins the compose project name so the produced images are predictably
# named ecommerce-platform-<service>, whatever directory this is invoked from.
Write-Host "Building images via docker compose..."
Push-Location $PlatformDir
try {
    docker compose -p ecommerce-platform build @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose build failed" }
}
finally { Pop-Location }

# ─── Retag for Kubernetes ────────────────────────────────────────────────────
Write-Host ""
foreach ($svc in ($Services + 'frontend')) {
    docker tag "ecommerce-platform-${svc}:latest" "ecommerce/${svc}:local"
    if ($LASTEXITCODE -ne 0) { throw "docker tag failed for $svc" }
    Write-Host "tagged ecommerce/${svc}:local"
}

Write-Host ""
Write-Host "Done. Deploy with .\deploy.ps1"
