#!/usr/bin/env bash
# Security scans that need no code in the services: dependency and image CVEs,
# committed secrets, infrastructure misconfiguration, and dynamic scans (DAST)
# of the running stack. Every tool runs in its own container, so nothing has to
# be installed locally. Each run writes reports to
# security-tests/reports/<timestamp>/ plus a summary.md.
#
#   ./run-security.sh                 # everything (sca secrets misconfig images dast-api dast-web npm)
#   ./run-security.sh sca secrets     # static checks only, no stack needed
#   GW=http://staging:8080 WEB=http://staging:3000 ./run-security.sh dast-api dast-web
#
# Scans:
#   sca       Trivy: known CVEs in every repo's pom.xml / package-lock.json
#   secrets   Gitleaks: secrets committed to any of the 13 repositories (whole history)
#   misconfig Trivy: k8s manifests, Dockerfiles and compose (runs as root, no limits, ...)
#   images    Trivy: OS and library CVEs in the ecommerce/*:local images
#   dast-api  OWASP ZAP API scan of every service's OpenAPI spec through the gateway,
#             authenticated as a fresh customer
#   dast-web  OWASP ZAP baseline (passive) scan of the SPA
#   npm       npm audit of the frontend's production dependencies
#
# Exit code: non-zero when any scan finds something at or above FAIL_ON
# (default CRITICAL for CVEs; any leaked secret; any ZAP FAIL-level alert).
# The JUnit and Playwright security suites are separate: see docs/testing.md.
set -uo pipefail

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.76.1}"
GITLEAKS_IMAGE="${GITLEAKS_IMAGE:-zricethezav/gitleaks:v8.30.1}"
ZAP_IMAGE="${ZAP_IMAGE:-zaproxy/zap-stable:2.17.0}"
FAIL_ON="${FAIL_ON:-CRITICAL}"

DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="$(cd "$DIR/.." && pwd)"
ROOT="$(cd "$PLATFORM/.." && pwd)"
SERVICES=(user-service product-service catalog-service order-service payment-service shipping-service review-service)

GW="${GW:-http://localhost:8080}"
WEB="${WEB:-http://localhost:3000}"
# Inside a container localhost is the container; Docker Desktop exposes the host
# as host.docker.internal (Linux CI: --network host and keep localhost).
NET_ARGS=()
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Darwin*)
    GW_IN="${GW/localhost/host.docker.internal}"; WEB_IN="${WEB/localhost/host.docker.internal}" ;;
  *) GW_IN="$GW"; WEB_IN="$WEB"; NET_ARGS=(--network host) ;;
esac

SCANS=("$@")
[[ ${#SCANS[@]} -eq 0 ]] && SCANS=(sca secrets misconfig images dast-api dast-web npm)

RUN="reports/$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/$RUN"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
FAILED=()
# Trivy's vulnerability DB is cached between runs here (ignored by git).
CACHE="$DIR/.cache"
mkdir -p "$CACHE/trivy"

# MSYS_NO_PATHCONV stops Git Bash rewriting container paths into Windows paths.
docker_run() { MSYS_NO_PATHCONV=1 docker run --rm "${NET_ARGS[@]}" "$@"; }

{
  echo "# Security scan $(date '+%Y-%m-%d %H:%M')"
  echo
  echo "Gateway: \`$GW\`, SPA: \`$WEB\`, fail on: \`$FAIL_ON\`"
  echo
  echo "| Scan | Result | Report |"
  echo "|---|---|---|"
} > "$SUMMARY"

record() { # name, exit code, report, note
  local result="pass"
  [[ "$2" -ne 0 ]] && { result="**FAIL**"; FAILED+=("$1"); }
  echo "| $1 | $result $4 | \`$3\` |" >> "$SUMMARY"
  echo "== $1: $result $4"
}

count() { # pattern, file: number of matching lines, 0 when the file is missing
  local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"
}

trivy() { # trivy args...; the vulnerability DB is cached in .cache/trivy
  docker_run -v "$ROOT:/src:ro" -v "$CACHE/trivy:/root/.cache/trivy" -v "$OUT:/out" "$TRIVY_IMAGE" "$@"
}

scan_sca() {
  # Scans what ships. Java: the Spring Boot fat jars in each repo's target/ (every bundled
  # library, transitive ones included). Trivy reads jars only in rootfs/image mode, and
  # its pom.xml analysis would resolve parent POMs from Maven Central, which rate-limits
  # (429) quickly. So: rootfs over the jars (build them first: ../build-all.sh), plus fs
  # over package-lock.json for the frontend.
  echo "-- sca: Trivy over the built jars and package-lock.json"
  local jars=()
  for repo in "$ROOT"/ecommerce-*/; do
    [[ -f "$repo/pom.xml" ]] || continue
    if ls "$repo"target/*.jar >/dev/null 2>&1; then jars+=("$(basename "$repo")"); else echo "   no jar in $(basename "$repo")/target: not scanned"; fi
  done
  trivy rootfs --scanners vuln --offline-scan --skip-dirs '**/node_modules' \
    --skip-dirs '**/src' --skip-files '**/pom.xml' --skip-files '**/package-lock.json' \
    --format json --output /out/sca-jars.json /src >/dev/null 2>"$OUT/sca.log"
  trivy fs --scanners vuln --skip-dirs '**/node_modules' \
    --format json --output /out/sca-npm.json /src/ecommerce-frontend >/dev/null 2>>"$OUT/sca.log"
  : > "$OUT/sca.txt"
  for part in jars npm; do
    trivy convert --format table --severity "$FAIL_ON,HIGH" --output "/out/sca-$part.txt" "/out/sca-$part.json" >/dev/null 2>>"$OUT/sca.log"
    cat "$OUT/sca-$part.txt" >> "$OUT/sca.txt" 2>/dev/null
  done
  local critical high
  critical=$(( $(count '"Severity": "CRITICAL"' "$OUT/sca-jars.json") + $(count '"Severity": "CRITICAL"' "$OUT/sca-npm.json") ))
  high=$(( $(count '"Severity": "HIGH"' "$OUT/sca-jars.json") + $(count '"Severity": "HIGH"' "$OUT/sca-npm.json") ))
  local rc=0
  case "$FAIL_ON" in
    CRITICAL) [[ $critical -gt 0 ]] && rc=1 ;;
    HIGH) [[ $((critical + high)) -gt 0 ]] && rc=1 ;;
  esac
  [[ -s "$OUT/sca-jars.json" && -s "$OUT/sca-npm.json" ]] || rc=1
  record sca "$rc" "$RUN/sca.txt" "(${#jars[@]} jars; $critical critical, $high high)"
}

scan_secrets() {
  echo "-- secrets: Gitleaks over the history of every repository"
  local rc=0 total=0
  for repo in "$ROOT"/ecommerce-*/; do
    local name; name="$(basename "$repo")"
    [[ -d "$repo/.git" ]] || continue
    docker_run -v "$repo:/repo:ro" -v "$OUT:/out" "$GITLEAKS_IMAGE" \
      git /repo --redact --no-banner --exit-code 1 \
      --report-format json --report-path "/out/secrets-$name.json" >/dev/null 2>&1 || rc=1
    total=$(( total + $(count '"RuleID"' "$OUT/secrets-$name.json") ))
  done
  record secrets "$rc" "$RUN/secrets-*.json" "($total leaks)"
}

scan_misconfig() {
  echo "-- misconfig: Trivy over k8s manifests, Dockerfiles and compose"
  trivy config --skip-dirs '**/node_modules' --skip-dirs '**/target'     --format json --output /out/misconfig.json /src >/dev/null 2>"$OUT/misconfig.log"
  trivy convert --format table --severity "$FAIL_ON,HIGH,MEDIUM" --output /out/misconfig.txt /out/misconfig.json >/dev/null 2>>"$OUT/misconfig.log"
  local critical high
  critical=$(count '"Severity": "CRITICAL"' "$OUT/misconfig.json")
  high=$(count '"Severity": "HIGH"' "$OUT/misconfig.json")
  local rc=0
  [[ $critical -gt 0 || ! -s "$OUT/misconfig.json" ]] && rc=1
  [[ "$FAIL_ON" == HIGH && $high -gt 0 ]] && rc=1
  record misconfig "$rc" "$RUN/misconfig.txt" "($critical critical, $high high)"
}

scan_images() {
  echo "-- images: Trivy over ecommerce/*:local"
  local rc=0
  for svc in service-discovery api-gateway "${SERVICES[@]}" notification-service frontend; do
    local image="ecommerce/$svc:local"
    docker image inspect "$image" >/dev/null 2>&1 || { echo "   skip $image (not built)"; continue; }
    docker_run -v /var/run/docker.sock:/var/run/docker.sock -v "$CACHE/trivy:/root/.cache/trivy" -v "$OUT:/out" \
      "$TRIVY_IMAGE" image --scanners vuln --skip-db-update --severity "$FAIL_ON,HIGH" --format table \
      --output "/out/image-$svc.txt" "$image" >/dev/null 2>>"$OUT/images.log"
    docker_run -v /var/run/docker.sock:/var/run/docker.sock -v "$CACHE/trivy:/root/.cache/trivy" \
      "$TRIVY_IMAGE" image --scanners vuln --skip-db-update --severity "$FAIL_ON" --exit-code 1 --quiet "$image" >/dev/null 2>>"$OUT/images.log" || rc=1
  done
  record images "$rc" "$RUN/image-*.txt" ""
}

customer_token() {
  local user="sec_$(date +%s)$RANDOM"
  curl -sf -o /dev/null -H 'Content-Type: application/json' "$GW/api/v1/users/register" \
    -d "{\"username\":\"$user\",\"email\":\"$user@example.test\",\"password\":\"Sec-scan-password-1\"}" || return 1
  curl -sf -H 'Content-Type: application/json' "$GW/api/v1/users/login" \
    -d "{\"username\":\"$user\",\"password\":\"Sec-scan-password-1\"}" | sed -E 's/.*"token":"([^"]+)".*/\1/'
}

scan_dast_api() {
  echo "-- dast-api: ZAP API scan of each service's OpenAPI spec through $GW"
  local token rc=0
  token="$(customer_token)" || { record dast-api 1 "-" "(stack not reachable at $GW)"; return; }
  chmod a+w "$OUT"
  for svc in "${SERVICES[@]}"; do
    # The replacer rule adds the customer's bearer token to every request ZAP sends.
    docker_run -v "$OUT:/zap/wrk:rw" -t "$ZAP_IMAGE" zap-api-scan.py \
      -t "$GW_IN/api-docs/$svc" -f openapi -O "$GW_IN" \
      -r "zap-api-$svc.html" -J "zap-api-$svc.json" -w "zap-api-$svc.md" \
      -c zap-rules.conf -I \
      -z "-config replacer.full_list(0).description=auth \
          -config replacer.full_list(0).enabled=true \
          -config replacer.full_list(0).matchtype=REQ_HEADER \
          -config replacer.full_list(0).matchstr=Authorization \
          -config replacer.full_list(0).regex=false \
          -config replacer.full_list(0).replacement=Bearer\ $token" >"$OUT/zap-api-$svc.log" 2>&1
    local code=$?
    # zap-api-scan exit codes: 0 clean, 1 FAIL alerts, 2 WARN alerts only, 3 error. -I makes WARN 0.
    [[ $code -eq 1 || $code -eq 3 ]] && rc=1
    echo "   $svc: exit $code ($(grep -oE 'FAIL-NEW: [0-9]+.*' "$OUT/zap-api-$svc.log" | tail -1))"
  done
  record dast-api "$rc" "$RUN/zap-api-*.html" ""
}

scan_dast_web() {
  echo "-- dast-web: ZAP baseline scan of $WEB"
  chmod a+w "$OUT"
  cp "$DIR/zap-rules.conf" "$OUT/" 2>/dev/null
  docker_run -v "$OUT:/zap/wrk:rw" -t "$ZAP_IMAGE" zap-baseline.py \
    -t "$WEB_IN" -r zap-web.html -J zap-web.json -w zap-web.md -c zap-rules.conf -I -j \
    >"$OUT/zap-web.log" 2>&1
  local code=$?
  echo "   $(grep -oE 'FAIL-NEW: [0-9]+.*' "$OUT/zap-web.log" | tail -1)"
  [[ $code -eq 1 || $code -eq 3 ]] && code=1 || code=0
  record dast-web "$code" "$RUN/zap-web.html" ""
}

scan_npm() {
  echo "-- npm: npm audit of the frontend's production dependencies"
  (cd "$ROOT/ecommerce-frontend" && npm audit --omit=dev --json > "$OUT/npm-audit.json")
  (cd "$ROOT/ecommerce-frontend" && npm audit --omit=dev --audit-level="$(echo "$FAIL_ON" | tr 'A-Z' 'a-z')" > "$OUT/npm-audit.txt")
  record npm $? "$RUN/npm-audit.txt" ""
}

cp "$DIR/zap-rules.conf" "$OUT/" 2>/dev/null
for scan in "${SCANS[@]}"; do
  case "$scan" in
    sca) scan_sca ;;
    secrets) scan_secrets ;;
    misconfig) scan_misconfig ;;
    images) scan_images ;;
    dast-api) scan_dast_api ;;
    dast-web) scan_dast_web ;;
    npm) scan_npm ;;
    *) echo "unknown scan: $scan"; exit 2 ;;
  esac
done

echo
cat "$SUMMARY"
[[ ${#FAILED[@]} -eq 0 ]]
