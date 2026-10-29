# ADR-011: Prometheus, Loki and Tempo behind Grafana, with OpenTelemetry tracing

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from `ecommerce-monitoring`, the compose file and the services' configuration.

## Context

A request in this platform crosses the gateway, one or more services, Feign
hops and Kafka topics. Debugging it from `docker logs` across 38 containers
doesn't scale, and resource problems (heap, connection pools, consumer lag)
need history, not snapshots.

## Decision

- **Metrics:** every Spring service exposes Micrometer metrics at `/actuator/prometheus`, with common tags `application` and `environment` and an `http.server.requests` histogram with SLO buckets (50 ms to 2 s). Prometheus scrapes them alongside exporters for Postgres (one per database, with custom queries), MongoDB, Kafka, node, cAdvisor, nginx and blackbox probes. Retention is 15 days. Alert rules go to Alertmanager.
- **Logs:** containers log to stdout. Promtail ships them to **Loki** (Docker socket discovery under compose, Kubernetes API discovery under k8s).
- **Traces:** Spring Boot's OpenTelemetry starter exports spans over OTLP/HTTP to **Tempo**, with sampling at 100 %.
- **One UI:** Grafana, provisioned from files, with the datasources and 8 dashboards (platform overview, JVM, gateway, databases, Kafka, containers, frontend, errors and latency).
- Keep all monitoring configuration in its own repository (`ecommerce-monitoring`) and share it byte-for-byte between compose and Kubernetes. Kubernetes gets it through a generated ConfigMap.

## Consequences

Positive:
- Metrics, logs and traces in one tool, with no code changes in the services beyond dependencies and configuration.
- The same dashboards and alerts work in both deployments.

Negative:
- About 15 extra containers and a meaningful share of the stack's memory.
- 100 % sampling is fine locally but too expensive anywhere with real traffic.
- Sharing `prometheus.yml` byte-for-byte prevents Kubernetes-only scrape jobs, such as the kubelet's cAdvisor endpoint, so per-pod container metrics are missing under Kubernetes.
- The decision was only half implemented, so the signals don't join up (details in [Observability](../observability.md#known-gaps)):
  - Traces cover the gateway → service hop only. Feign calls lack `feign-micrometer`, and Kafka observation is never enabled.
  - No log pattern prints a trace ID, so Grafana's log ↔ trace links are dead.
  - Exemplars are not stored.
  - Correlation IDs are per service: the gateway creates none and no service forwards one.
  - The services disagree on log-field order, and the compose and k8s promtail parsers each match only half of them.

## Related

[Observability](../observability.md) · [ecommerce-monitoring/README.md](../../../ecommerce-monitoring/README.md)
