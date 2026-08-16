#!/usr/bin/env bash
#
# Removes the platform. Data volumes survive by default: deleting a namespace
# does take its PVCs with it, so the databases, Kafka log, Prometheus TSDB and
# Grafana state are only destroyed when --with-data is passed explicitly.
set -euo pipefail

K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
NS=ecommerce
WITH_DATA=false

for arg in "$@"; do
  case $arg in
    --with-data) WITH_DATA=true ;;
    *) echo "unknown argument: $arg"; exit 1 ;;
  esac
done

if $WITH_DATA; then
  echo "Deleting namespace $NS including all PersistentVolumeClaims."
  read -r -p "This destroys every database. Continue? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || exit 1
  kubectl delete namespace "$NS" --wait=true
else
  # Deleting the workloads rather than the namespace is what keeps the PVCs;
  # they are namespace-scoped and would go with it.
  kubectl delete -k "$K8S_DIR" --ignore-not-found=true \
    --selector='app.kubernetes.io/part-of=ecommerce-platform' || true
  kubectl -n "$NS" delete deployment,statefulset,daemonset --all
  echo
  echo "Workloads removed. PersistentVolumeClaims kept:"
  kubectl -n "$NS" get pvc
  echo
  echo "Re-run ./deploy.sh to bring it back with the same data,"
  echo "or ./teardown.sh --with-data to wipe it."
fi
