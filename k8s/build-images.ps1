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

# ─── Refresh the kind node's image cache (kind provisioner only) ─────────────
# Under Docker Desktop's kind provisioner the node runs its own containerd
# with its own image cache. It can pull local-only images straight out of
# Docker's image store, but imagePullPolicy: IfNotPresent never asks for a tag
# it already holds - so a rebuild under the same ecommerce/<svc>:local tag is
# invisible and the pod quietly keeps running the previous jar. An explicit
# pull on the node updates the tag (only changed layers transfer). The kubeadm
# provisioner shares Docker's image store directly and has no such node.
$Node = 'desktop-control-plane'
# Probe without letting a "No such container" on stderr become a terminating
# error under $ErrorActionPreference = 'Stop' (PowerShell 5.1 wraps native
# stderr lines in ErrorRecords when they are redirected).
$NodePresent = $false
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    cmd /c "docker exec $Node true >NUL 2>&1"
    $NodePresent = ($LASTEXITCODE -eq 0)
}
finally { $ErrorActionPreference = $prevEap }
if ($NodePresent) {
    Write-Host ""
    Write-Host "kind provisioner detected ($Node): refreshing its image cache..."
    foreach ($svc in ($Services + 'frontend')) {
        cmd /c "docker exec $Node crictl pull docker.io/ecommerce/${svc}:local >NUL 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "crictl pull failed for ecommerce/${svc}:local on $Node" }
        Write-Host "refreshed ecommerce/${svc}:local on $Node"
    }
}

Write-Host ""
Write-Host "Done. Deploy with .\deploy.ps1"
