# ADR-012: Kubernetes manifests mirror the compose stack one-to-one

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from `ecommerce-platform/k8s/`.

## Context

The platform first ran on Docker Compose. Moving it to Kubernetes (Docker
Desktop) was a learning goal, but maintaining two divergent topologies would
double every configuration change, and the monitoring configuration addresses
everything by service name and port.

## Decision

- Translate the compose stack into plain manifests applied with Kustomize: the same 38 workloads (8 StatefulSets, 27 Deployments, 3 DaemonSets) with **identical service names, ports and credentials**.
- Replace compose-only mechanisms with their nearest equivalents: busybox init containers for `depends_on: service_healthy`, split liveness and readiness probes for health checks, a `java-env` ConfigMap for the `x-java-env` anchor, Secrets for credentials, and `type: LoadBalancer` Services for host ports.
- Keep requests far below limits. Limits equal compose's `mem_limit`; requests are about 40 % of that, so the stack fits on one Docker Desktop node.
- Generate the monitoring ConfigMap from the sibling repository instead of copying files ([ADR-011](ADR-011-observability-stack.md)).
- Use locally built images (`ecommerce/<name>:local`, `IfNotPresent`) with no registry.

## Consequences

Positive:
- One mental model for both environments. Monitoring config, runbooks and scripts carry over unchanged.
- Kubernetes-specific behaviour is isolated and documented: the Kafka listener binding, `enableServiceLinks: false`, pod-IP registration, promtail discovery, volume chown init containers.

Negative:
- Single replica everywhere, single-node Kafka and databases, and Secrets in plain manifests. It is a local cluster, not a production topology.
- The two provisioners (kubeadm and kind) differ in runtime, log handling and image caching. A Docker Desktop upgrade can switch between them and wipe the cluster.
- Plain manifests with no Helm: every change to the compose file must be mirrored by hand.

## Update (2026-10-30)

The two places where a manifest holds a copy of a file from another repository are now compared by scripts in `k8s/`. The decision is unchanged.

- **Promtail.** Its Kubernetes config is inline in `60-monitoring.yaml`, because it discovers pods through the Kubernetes API instead of containers through the Docker socket. Everything after the runtime envelope (multiline, `level` label, structured metadata, counters, DEBUG drop, per-container limit) has to equal the pipeline in `ecommerce-monitoring/promtail/promtail-config.yml`. `check-promtail-parity.sh` compares them. `sync-monitoring-config.sh`, which `deploy.sh` runs, calls it and prints a warning on a difference. The envelope is chosen per line (`docker` for Docker's JSON, `cri` for anything else), so a switch between kubeadm and kind needs no edit.
- **Frontend nginx.** The `frontend-nginx` ConfigMap in `50-frontend.yaml` is `ecommerce-frontend/nginx.conf` except for the upstream: no `resolver`, and a literal `proxy_pass http://api-gateway:8080;`. `check-frontend-nginx-parity.sh` compares the two directive by directive. The `checksum/nginx-config` annotation (`v2`) has to change with the ConfigMap, because a subPath mount never sees a ConfigMap update.

CI shellchecks both scripts and parses the manifests; it does not run the parity checks, which need the sibling repositories. The hardening settings of the same change were mirrored by hand: Prometheus `--storage.tsdb.retention.size`, Kafka retention and logger levels, `mongod --quiet --slowms 1000`, `-XX:-HeapDumpOnOutOfMemoryError`, the gateway's `JAVA_TOOL_OPTIONS`, probe timeouts of 5 s (compose's healthcheck timeout), a 10-minute startup probe on Loki and Tempo, and the Java services' stop grace period (60 s under compose, 90 s under Kubernetes, where the `preStop` drain comes first).

Two Kubernetes-only deviations follow from notification-service's health including its Kafka listeners: its startup probe uses the liveness endpoint, and its Service publishes not-ready addresses so that Prometheus keeps scraping it while the broker is down.

## Related

[k8s/README.md](../../k8s/README.md) · [Runbook](../runbook.md)
