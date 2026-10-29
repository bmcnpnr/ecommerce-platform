#!/usr/bin/env bash
# Runs a k6 load test in the grafana/k6 container against a running stack, so
# nothing has to be installed locally. Writes a per-run report to
# load-tests/reports/<script>-<profile>-<timestamp>/ (summary.json + summary.txt).
#
#   ./run-load.sh browse.js                          # smoke profile (1 VU, 30s)
#   PROFILE=load   ./run-load.sh browse.js           # expected peak
#   PROFILE=stress ./run-load.sh checkout.js         # 4x peak
#   GW=http://staging:8080 ./run-load.sh browse.js
#
# Exit code is k6's: non-zero when a threshold (p95 latency, error rate) fails.
set -euo pipefail

K6_IMAGE="grafana/k6:0.54.0"
SCRIPT="${1:?usage: run-load.sh <browse.js|checkout.js>}"
PROFILE="${PROFILE:-smoke}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# Inside the container localhost is the container itself; Docker Desktop exposes
# the host as host.docker.internal (Linux CI: use --network host and keep localhost).
GW="${GW:-http://localhost:8080}"
NET_ARGS=()
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Darwin*) GW="${GW/localhost/host.docker.internal}" ;;
  *) NET_ARGS=(--network host) ;;
esac

# Seeding products needs the admin (product writes are admin-only).
if [ -z "${ADMIN_PASSWORD:-}" ] && [ -f "$DIR/../.env" ]; then
  set -a; . "$DIR/../.env"; set +a
fi

RUN="reports/${SCRIPT%.js}-$PROFILE-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR/$RUN"

# MSYS_NO_PATHCONV stops Git Bash rewriting /scripts into a Windows path.
MSYS_NO_PATHCONV=1 docker run --rm -i "${NET_ARGS[@]}" \
  -v "$DIR:/scripts" -w /scripts \
  -e GW="$GW" -e PROFILE="$PROFILE" \
  -e ADMIN_USERNAME="${ADMIN_USERNAME:-admin}" -e ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
  "$K6_IMAGE" run --summary-export "$RUN/summary.json" "$SCRIPT" 2>&1 | tee "$DIR/$RUN/summary.txt"
exit "${PIPESTATUS[0]}"
