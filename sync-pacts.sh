#!/usr/bin/env bash
# Regenerates every Pact contract from its consumer, copies it into the provider
# repository, and replays it against the provider.
#
# Each repository is its own Git project and CI pipeline and there is no Pact
# broker, so the pact files themselves are the hand-off: a consumer writes
# target/pacts/<consumer>-<provider>.json, the provider keeps a committed copy in
# src/test/resources/pacts/ and verifies it on every build. Run this after
# changing a consumer's expectations (its *ConsumerPactTest) and commit the
# updated copies in the provider repositories together with the consumer change.
#
#   ./sync-pacts.sh                # regenerate, copy, verify
#   ./sync-pacts.sh --no-verify    # regenerate and copy only
#   ./sync-pacts.sh --verify-only  # replay the committed pacts against every provider
#
# Contract map (consumer -> provider): see README.md "Contract tests".
set -euo pipefail

JAVA_HOME="C:/Program Files/Java/jdk-25.0.2"
MAVEN_HOME="C:/Users/burak/apache-maven-3.9.14"
MVN="$MAVEN_HOME/bin/mvn"

export JAVA_HOME
export PATH="$MAVEN_HOME/bin:$JAVA_HOME/bin:$PATH"

VERIFY=true
GENERATE=true
for arg in "$@"; do
    case $arg in
        --no-verify)   VERIFY=false ;;
        --verify-only) GENERATE=false ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

# Repositories that own consumer pact tests (*ConsumerPactTest).
CONSUMERS=(
    ecommerce-api-gateway
    ecommerce-order-service
    ecommerce-catalog-service
    ecommerce-review-service
    ecommerce-shipping-service
    ecommerce-notification-service
)

# Repositories that own provider verification tests (*ProviderPactTest).
PROVIDERS=(
    ecommerce-product-service
    ecommerce-user-service
    ecommerce-review-service
    ecommerce-order-service
    ecommerce-payment-service
    ecommerce-shipping-service
)

# Script lives in ecommerce-platform/; sibling repos are one level up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MVN_COMMON=(-B -q -Dsurefire.failIfNoSpecifiedTests=false)
FAILED=()

echo ""
echo "============================================"
echo "   Ecommerce Platform - Sync Pact contracts "
echo "============================================"

if $GENERATE; then
    for repo in "${CONSUMERS[@]}"; do
        consumer="${repo#ecommerce-}"          # spring.application.name == repo name minus prefix
        echo "---------- generate: $consumer ----------"
        if ! (cd "$ROOT/$repo" && "$MVN" "${MVN_COMMON[@]}" clean test -Dtest='*ConsumerPactTest'); then
            echo -e "\e[31mconsumer tests failed in $repo\e[0m"
            FAILED+=("$repo (consumer)")
            continue
        fi
        shopt -s nullglob
        for pact in "$ROOT/$repo"/target/pacts/*.json; do
            base="$(basename "$pact" .json)"
            provider="${base#"$consumer"-}"
            dest="$ROOT/ecommerce-$provider/src/test/resources/pacts"
            if [[ ! -d "$ROOT/ecommerce-$provider" ]]; then
                echo -e "\e[31mno repository for provider '$provider' ($pact)\e[0m"
                FAILED+=("$base (no provider repo)")
                continue
            fi
            mkdir -p "$dest"
            if [[ -f "$dest/$base.json" ]] && cmp -s "$pact" "$dest/$base.json"; then
                echo "  unchanged  $base.json"
            else
                cp "$pact" "$dest/$base.json"
                echo -e "  \e[33mupdated\e[0m    $base.json -> ecommerce-$provider/src/test/resources/pacts/"
            fi
        done
        shopt -u nullglob
    done
fi

if $VERIFY; then
    for repo in "${PROVIDERS[@]}"; do
        echo "---------- verify: ${repo#ecommerce-} ----------"
        if (cd "$ROOT/$repo" && "$MVN" "${MVN_COMMON[@]}" test -Dtest='*ProviderPactTest'); then
            echo -e "\e[32mverified   $repo\e[0m"
        else
            echo -e "\e[31mVERIFICATION FAILED  $repo  (see target/surefire-reports)\e[0m"
            FAILED+=("$repo (provider)")
        fi
    done
fi

echo "============================================"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo -e "\e[32mAll pacts in sync.\e[0m"
    if $GENERATE; then
        echo "Commit any updated src/test/resources/pacts/*.json in the provider repositories."
    fi
else
    echo -e "\e[31mFailures:\e[0m"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
