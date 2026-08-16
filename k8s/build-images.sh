#!/usr/bin/env bash
#
# Builds the eleven application images and tags them as ecommerce/<name>:local,
# which is what the manifests reference.
#
# The Dockerfiles COPY a pre-built jar rather than compiling inside the image,
# so run ../build-all.sh (or build-all.ps1) first. Skipping that step ships the
# previous jar and looks exactly like "my fix did not apply" — this script
# fails loudly instead.
#
# Images are built by `docker compose build` so the layer cache and build
# context stay shared with the compose stack; the retag afterwards is what
# gives Kubernetes a stable name to pull. The manifests use
# imagePullPolicy: IfNotPresent, so the local image is used and no registry is
# contacted — Docker Desktop's kubeadm cluster reads the same image store.
set -euo pipefail

K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM_DIR="$(cd "$K8S_DIR/.." && pwd)"
ROOT="$(cd "$PLATFORM_DIR/.." && pwd)"

SERVICES=(
  service-discovery
  api-gateway
  user-service
  product-service
  catalog-service
  order-service
  payment-service
  shipping-service
  review-service
  notification-service
)

# ─── Pre-flight: every jar must exist ────────────────────────────────────────
missing=0
for svc in "${SERVICES[@]}"; do
  if ! ls "$ROOT/ecommerce-$svc/target/$svc"-*.jar >/dev/null 2>&1; then
    echo "MISSING JAR: ecommerce-$svc/target/$svc-*.jar"
    missing=1
  fi
done
if [[ $missing -ne 0 ]]; then
  echo
  echo "Run ../build-all.sh (or build-all.ps1) first — the Dockerfiles copy a"
  echo "pre-built jar and cannot compile it themselves."
  exit 1
fi

# ─── Build ───────────────────────────────────────────────────────────────────
# -p pins the compose project name so the produced images are predictably
# named ecommerce-platform-<service>, whatever directory this is invoked from.
echo "Building images via docker compose..."
(cd "$PLATFORM_DIR" && docker compose -p ecommerce-platform build "$@")

# ─── Retag for Kubernetes ────────────────────────────────────────────────────
echo
for svc in "${SERVICES[@]}" frontend; do
  docker tag "ecommerce-platform-$svc:latest" "ecommerce/$svc:local"
  echo "tagged ecommerce/$svc:local"
done

echo
echo "Done. Deploy with ./deploy.sh"
