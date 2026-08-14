#!/usr/bin/env bash
set -euo pipefail

JAVA_HOME="C:/Program Files/Java/jdk-25.0.2"
MAVEN_HOME="C:/Users/burak/apache-maven-3.9.14"
MVN="$MAVEN_HOME/bin/mvn"

export JAVA_HOME
export PATH="$MAVEN_HOME/bin:$JAVA_HOME/bin:$PATH"

# ─── Argument parsing ────────────────────────────────────────────────────────
SKIP_TESTS=false
WITH_DOCKER=true   # Rebuild Docker images after Maven by default
NO_CACHE=false     # Pass --no-cache to docker compose build

for arg in "$@"; do
    case $arg in
        --skip-tests) SKIP_TESTS=true ;;
        --no-docker)  WITH_DOCKER=false ;;  # Maven only, skip Docker rebuild
        --no-cache)   NO_CACHE=true ;;      # Force Docker layer cache bypass
    esac
done

MVN_ARGS="clean install"
if $SKIP_TESTS; then
    MVN_ARGS="clean install -Dmaven.test.skip=true"
fi

SERVICES=(
    ecommerce-service-discovery
    ecommerce-api-gateway
    ecommerce-user-service
    ecommerce-product-service
    ecommerce-catalog-service
    ecommerce-order-service
    ecommerce-payment-service
    ecommerce-shipping-service
    ecommerce-review-service
    ecommerce-notification-service
)

# Script lives in ecommerce-platform/; sibling repos are one level up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

declare -A RESULTS
START=$(date +%s)

echo ""
echo "============================================"
echo "   Ecommerce Platform - Build All Services  "
echo "============================================"
echo "Java  : $JAVA_HOME"
echo "Maven : $MAVEN_HOME"
echo "Tests : $(if $SKIP_TESTS; then echo 'Skipped'; else echo 'Enabled'; fi)"
echo "Docker: $(if $WITH_DOCKER; then echo "Rebuild images after Maven"; else echo "Skipped (--no-docker)"; fi)"
echo "============================================"
echo ""

# ─── Maven builds ────────────────────────────────────────────────────────────
for svc in "${SERVICES[@]}"; do
    echo "---------- $svc ----------"
    SVC_START=$(date +%s)
    if (cd "$ROOT/$svc" && $MVN $MVN_ARGS); then
        SVC_ELAPSED=$(( $(date +%s) - SVC_START ))
        echo -e "\e[32mPASSED: $svc (${SVC_ELAPSED}s)\e[0m"
        RESULTS[$svc]="SUCCESS"
    else
        SVC_ELAPSED=$(( $(date +%s) - SVC_START ))
        echo -e "\e[31mFAILED: $svc (${SVC_ELAPSED}s)\e[0m"
        RESULTS[$svc]="FAILED"
    fi
    echo ""
done

TOTAL=$(( $(date +%s) - START ))
SUCCESS_COUNT=0
FAIL_COUNT=0

echo "============================================"
echo "   BUILD SUMMARY  (${TOTAL}s total)"
echo "============================================"
for svc in "${SERVICES[@]}"; do
    if [[ "${RESULTS[$svc]}" == "SUCCESS" ]]; then
        echo -e "\e[32m[OK]   $svc\e[0m"
        (( SUCCESS_COUNT += 1 ))
    else
        echo -e "\e[31m[FAIL] $svc\e[0m"
        (( FAIL_COUNT += 1 )) || true  # '|| true' guards against set -e when count stays 0
    fi
done
echo "--------------------------------------------"
if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "\e[32m$SUCCESS_COUNT passed, $FAIL_COUNT failed\e[0m"
else
    echo -e "\e[31m$SUCCESS_COUNT passed, $FAIL_COUNT failed\e[0m"
fi
echo "============================================"

# ─── Docker image rebuild ────────────────────────────────────────────────────
# This step copies the freshly built JARs into Docker images so that
# 'docker compose up' actually runs the new code. Without this step,
# Docker reuses cached images that contain the old JARs.
if $WITH_DOCKER; then
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo ""
        echo -e "\e[33mSkipping Docker build: $FAIL_COUNT Maven build(s) failed.\e[0m"
    else
        echo ""
        echo "============================================"
        echo "   Rebuilding Docker images               "
        echo "============================================"
        DOCKER_ARGS=""
        if $NO_CACHE; then
            DOCKER_ARGS="--no-cache"
        fi
        # Run from SCRIPT_DIR so docker compose finds docker-compose.yml
        (cd "$SCRIPT_DIR" && docker compose build $DOCKER_ARGS)
        echo ""
        echo -e "\e[32mDocker images rebuilt successfully.\e[0m"
        echo -e "Run \e[1mdocker compose up -d\e[0m to start the stack."
    fi
fi

exit $FAIL_COUNT
