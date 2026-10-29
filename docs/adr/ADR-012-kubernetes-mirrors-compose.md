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

## Related

[k8s/README.md](../../k8s/README.md) · [Runbook](../runbook.md)
