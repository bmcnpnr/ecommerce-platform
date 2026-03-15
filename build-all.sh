#!/usr/bin/env bash
set -euo pipefail

JAVA_HOME="C:/Program Files/Java/jdk-25.0.2"
MAVEN_HOME="C:/Users/burak/apache-maven-3.9.14"
MVN="$MAVEN_HOME/bin/mvn"

export JAVA_HOME
export PATH="$MAVEN_HOME/bin:$JAVA_HOME/bin:$PATH"

SKIP_TESTS=false
if [[ "${1:-}" == "--skip-tests" ]]; then
    SKIP_TESTS=true
fi

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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
declare -A RESULTS
START=$(date +%s)

echo ""
echo "============================================"
echo "   Ecommerce Platform - Build All Services  "
echo "============================================"
echo "Java  : $JAVA_HOME"
echo "Maven : $MAVEN_HOME"
echo "Tests : $(if $SKIP_TESTS; then echo 'Skipped'; else echo 'Enabled'; fi)"
echo "============================================"
echo ""

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
        (( SUCCESS_COUNT++ ))
    else
        echo -e "\e[31m[FAIL] $svc\e[0m"
        (( FAIL_COUNT++ ))
    fi
done
echo "--------------------------------------------"
if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "\e[32m$SUCCESS_COUNT passed, $FAIL_COUNT failed\e[0m"
else
    echo -e "\e[31m$SUCCESS_COUNT passed, $FAIL_COUNT failed\e[0m"
fi
echo "============================================"

exit $FAIL_COUNT
