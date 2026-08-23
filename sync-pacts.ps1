param(
    [switch]$NoVerify,    # regenerate and copy only
    [switch]$VerifyOnly   # replay the committed pacts against every provider
)

# Regenerates every Pact contract from its consumer, copies it into the provider
# repository, and replays it against the provider. PowerShell twin of sync-pacts.sh;
# see that file and README.md "Contract tests" for the why.

$JAVA_HOME = 'C:\Program Files\Java\jdk-25.0.2'
$MAVEN_HOME = 'C:\Users\burak\apache-maven-3.9.14'
$MVN = "$MAVEN_HOME\bin\mvn.cmd"

$env:JAVA_HOME = $JAVA_HOME
$env:PATH = "$MAVEN_HOME\bin;$JAVA_HOME\bin;$env:PATH"

# Repositories that own consumer pact tests (*ConsumerPactTest).
$consumers = @(
    'ecommerce-api-gateway',
    'ecommerce-order-service',
    'ecommerce-catalog-service',
    'ecommerce-review-service',
    'ecommerce-shipping-service',
    'ecommerce-notification-service'
)

# Repositories that own provider verification tests (*ProviderPactTest).
$providers = @(
    'ecommerce-product-service',
    'ecommerce-user-service',
    'ecommerce-review-service',
    'ecommerce-order-service',
    'ecommerce-payment-service',
    'ecommerce-shipping-service'
)

# Script lives in ecommerce-platform/; sibling repos are one level up.
$ROOT = Split-Path -Parent $PSScriptRoot
$mvnCommon = @('-B', '-q', '-Dsurefire.failIfNoSpecifiedTests=false')
$failed = @()

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Ecommerce Platform - Sync Pact contracts " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

if (-not $VerifyOnly) {
    foreach ($repo in $consumers) {
        $consumer = $repo -replace '^ecommerce-', ''   # spring.application.name == repo name minus prefix
        Write-Host "---------- generate: $consumer ----------"
        Push-Location (Join-Path $ROOT $repo)
        try {
            & $MVN @mvnCommon clean test "-Dtest=*ConsumerPactTest"
            $ok = ($LASTEXITCODE -eq 0)
        } finally {
            Pop-Location
        }
        if (-not $ok) {
            Write-Host "consumer tests failed in $repo" -ForegroundColor Red
            $failed += "$repo (consumer)"
            continue
        }
        $pactDir = Join-Path $ROOT "$repo\target\pacts"
        if (Test-Path $pactDir) {
            Get-ChildItem -Path $pactDir -Filter '*.json' | ForEach-Object {
                $base = $_.BaseName
                $provider = $base.Substring($consumer.Length + 1)
                $providerRepo = Join-Path $ROOT "ecommerce-$provider"
                if (-not (Test-Path $providerRepo)) {
                    Write-Host "no repository for provider '$provider' ($($_.FullName))" -ForegroundColor Red
                    $failed += "$base (no provider repo)"
                    return
                }
                $dest = Join-Path $providerRepo 'src\test\resources\pacts'
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                $target = Join-Path $dest $_.Name
                if ((Test-Path $target) -and ((Get-FileHash $_.FullName).Hash -eq (Get-FileHash $target).Hash)) {
                    Write-Host "  unchanged  $($_.Name)"
                } else {
                    Copy-Item $_.FullName $target -Force
                    Write-Host "  updated    $($_.Name) -> ecommerce-$provider/src/test/resources/pacts/" -ForegroundColor Yellow
                }
            }
        }
    }
}

if (-not $NoVerify) {
    foreach ($repo in $providers) {
        Write-Host "---------- verify: $($repo -replace '^ecommerce-', '') ----------"
        Push-Location (Join-Path $ROOT $repo)
        try {
            & $MVN @mvnCommon test "-Dtest=*ProviderPactTest"
            $ok = ($LASTEXITCODE -eq 0)
        } finally {
            Pop-Location
        }
        if ($ok) {
            Write-Host "verified   $repo" -ForegroundColor Green
        } else {
            Write-Host "VERIFICATION FAILED  $repo  (see target\surefire-reports)" -ForegroundColor Red
            $failed += "$repo (provider)"
        }
    }
}

Write-Host "============================================"
if ($failed.Count -eq 0) {
    Write-Host "All pacts in sync." -ForegroundColor Green
    if (-not $VerifyOnly) {
        Write-Host "Commit any updated src\test\resources\pacts\*.json in the provider repositories."
    }
} else {
    Write-Host "Failures:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
