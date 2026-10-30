#!/usr/bin/env bash
#
# Fails when the Kubernetes frontend-nginx ConfigMap (50-frontend.yaml) and
# ecommerce-frontend/nginx.conf differ in anything but the upstream.
#
# The pod does not use the nginx.conf baked into the image: the ConfigMap replaces
# it, because the image's copy resolves the gateway through Docker's DNS
# (127.0.0.11), which a pod does not have. The ConfigMap is therefore a copy, and a
# copy drifts: it once went on serving the old proxy-only config, without the
# security headers (S-7), the timeouts, the JSON 503 and the no-actuator rule, long
# after the frontend repository had them. This compares the two directive by
# directive (comments, blank lines and indentation are ignored) and fails on any
# difference except the three lines that are Kubernetes-specific by design:
#
#   compose                                       Kubernetes
#   resolver ... ; resolver_timeout ...;          (none)
#   set $api_gateway api-gateway;                 (none)
#   proxy_pass http://$api_gateway:8080$request_uri;   proxy_pass http://api-gateway:8080;
#
#   ./check-frontend-nginx-parity.sh      # exit 0 when they agree, 1 with a diff otherwise
#
# After changing the ConfigMap, change the checksum/nginx-config annotation in
# 50-frontend.yaml too, or running pods keep the old file (subPath mounts are not
# refreshed).
set -euo pipefail

K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTEND_CONF="$K8S_DIR/../../ecommerce-frontend/nginx.conf"
K8S_MANIFEST="$K8S_DIR/50-frontend.yaml"

# Directives only: no comments, no blank lines, no indentation, single spaces.
normalize() {
  tr -d '\r' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g' |
    grep -v -e '^#' -e '^$' || true
}

# The compose file with its three Docker-DNS lines turned into their Kubernetes form.
frontend_as_k8s() {
  normalize < "$FRONTEND_CONF" |
    grep -v -e '^resolver ' -e '^resolver_timeout ' -e '^set \$api_gateway ' |
    sed 's#^proxy_pass http://\$api_gateway:8080\$request_uri;$#proxy_pass http://api-gateway:8080;#'
}

# default.conf of the frontend-nginx ConfigMap, un-indented.
k8s_configmap() {
  tr -d '\r' < "$K8S_MANIFEST" |
    awk '
      /^  default\.conf: \|/ {block = 1; next}
      block && /^---/        {block = 0}
      block {print}' |
    normalize
}

expected="$(frontend_as_k8s)"
actual="$(k8s_configmap)"

if [[ -z "$expected" || -z "$actual" ]]; then
  echo "check-frontend-nginx-parity: could not read $FRONTEND_CONF or the ConfigMap in $K8S_MANIFEST" >&2
  exit 2
fi

if diff -u --label "ecommerce-frontend/nginx.conf (upstream adapted)" --label "50-frontend.yaml frontend-nginx" \
     <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"); then
  echo "frontend nginx config identical apart from the upstream ($(printf '%s\n' "$expected" | wc -l | tr -d ' ') directives)"
else
  echo >&2
  echo "The frontend-nginx ConfigMap no longer matches ecommerce-frontend/nginx.conf." >&2
  echo "Copy the change into 50-frontend.yaml (upstream lines excepted) and bump checksum/nginx-config." >&2
  exit 1
fi
