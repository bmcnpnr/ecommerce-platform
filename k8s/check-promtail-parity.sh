#!/usr/bin/env bash
#
# Fails when the Kubernetes Promtail pipeline and the compose one disagree.
#
# Promtail's Kubernetes config is inline in 60-monitoring.yaml, because it finds
# pods through the API and the compose file finds containers through the Docker
# socket, so the file cannot be reused. Everything it does to a log line after the
# runtime's envelope is unwrapped (multiline, level label, structured metadata,
# counters, DEBUG drop, per-container limit) must still be the compose pipeline in
# ecommerce-monitoring/promtail/promtail-config.yml, character for character. The two
# drifted once (finding O-3: opposite field orders, so each parser matched half of
# the services); this is the guard against it happening again.
#
#   ./check-promtail-parity.sh        # exit 0 when identical, 1 with a diff otherwise
set -euo pipefail

K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_CFG="$K8S_DIR/../../ecommerce-monitoring/promtail/promtail-config.yml"
K8S_MANIFEST="$K8S_DIR/60-monitoring.yaml"

# Compose: every stage after `    pipeline_stages:`, which sit at 6 spaces.
compose_pipeline() {
  tr -d '\r' < "$COMPOSE_CFG" |
    awk '/^    pipeline_stages:/ {on = 1; next} on {print}' |
    sed 's/^      //'
}

# Kubernetes: inside the promtail-config.yml block, everything after the `cri` stage
# (the last of the two runtime stages) up to `relabel_configs:`, at 10 spaces.
k8s_pipeline() {
  tr -d '\r' < "$K8S_MANIFEST" |
    awk '
      /^  promtail-config\.yml: \|/ {block = 1; next}
      block && /^---/               {block = 0}
      block && /^ +- cri: \{\}/      {on = 1; next}
      block && /^        relabel_configs:/ {on = 0}
      on {print}' |
    sed 's/^          //'
}

compose="$(compose_pipeline)"
k8s="$(k8s_pipeline)"

if [[ -z "$compose" || -z "$k8s" ]]; then
  echo "check-promtail-parity: could not find a pipeline in $COMPOSE_CFG or $K8S_MANIFEST" >&2
  exit 2
fi

if diff -u --label "compose (promtail-config.yml)" --label "kubernetes (60-monitoring.yaml)" \
     <(printf '%s\n' "$compose") <(printf '%s\n' "$k8s"); then
  echo "promtail pipelines identical ($(printf '%s\n' "$compose" | wc -l | tr -d ' ') lines)"
else
  echo >&2
  echo "The Kubernetes promtail pipeline differs from the compose one. Logs would be parsed" >&2
  echo "differently on the two platforms. Copy the change across (see ADR-012)." >&2
  exit 1
fi
