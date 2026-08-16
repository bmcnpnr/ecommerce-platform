#!/usr/bin/env bash
#
# Applies the whole platform to the current kubectl context and waits for it.
#
# Safe to re-run: everything is `kubectl apply`, and the wait phases are
# ordered the way the stack actually comes up rather than alphabetically.
set -euo pipefail

K8S_DIR="$(cd "$(dirname "$0")" && pwd)"
NS=ecommerce

CONTEXT="$(kubectl config current-context)"
echo "Context : $CONTEXT"
if [[ "$CONTEXT" != "docker-desktop" ]]; then
  read -r -p "That is not docker-desktop. Continue? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || exit 1
fi

echo "Rendering monitoring config from ecommerce-monitoring/..."
bash "$K8S_DIR/sync-monitoring-config.sh"

echo
echo "Applying manifests..."
kubectl apply -k "$K8S_DIR"

# Infrastructure first: nothing else can pass its init containers until the
# databases, Kafka and Eureka answer, and rollout waits are cheap when the
# resource is already up.
echo
echo "Waiting for databases and Kafka..."
kubectl -n "$NS" rollout status statefulset/kafka --timeout=5m
for db in userdb productdb catalogdb orderdb paymentdb shippingdb reviewdb; do
  kubectl -n "$NS" rollout status "statefulset/$db" --timeout=5m
done

echo
echo "Waiting for service discovery..."
kubectl -n "$NS" rollout status deployment/service-discovery --timeout=5m

# Ten JVMs starting at once on a laptop-sized node contend badly; the startup
# probes allow five minutes each and the timeout here has to cover that.
echo
echo "Waiting for application services..."
for svc in user-service product-service catalog-service order-service \
           payment-service shipping-service review-service \
           notification-service api-gateway frontend; do
  kubectl -n "$NS" rollout status "deployment/$svc" --timeout=10m
done

echo
echo "Waiting for monitoring..."
for svc in prometheus alertmanager loki tempo grafana; do
  kubectl -n "$NS" rollout status "deployment/$svc" --timeout=5m
done

echo
kubectl -n "$NS" get pods -o wide
echo
echo "Frontend        http://localhost:3000"
echo "API gateway     http://localhost:8080"
echo "Eureka          http://localhost:8761"
echo "Grafana         http://localhost:3001   (admin/admin)"
echo "Prometheus      http://localhost:9090"
echo "Alertmanager    http://localhost:9093"
echo "Kafka UI        http://localhost:8090"
