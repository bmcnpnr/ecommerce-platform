# ADR-005: Client-side discovery with Eureka, also on Kubernetes

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from the code and the k8s manifests' comments.

## Context

The platform started on Docker Compose, which has no service registry or load
balancing across replicas. The application code addresses peers by logical
name: `lb://product-service` in gateway routes, `@FeignClient(name =
"product-service")` in callers. Later the stack moved to Kubernetes as well,
where Services and kube-dns already provide discovery.

## Decision

- Run a standalone **Eureka** server (`service-discovery`). Every Spring service registers with it, and callers resolve peers through Spring Cloud LoadBalancer.
- **Keep Eureka on Kubernetes too**, layered on top of Kubernetes Services, so the application code and the compose stack stay unchanged. Instances register their **pod IP** (`EUREKA_INSTANCE_PREFER_IP_ADDRESS=true`), because pod hostnames don't resolve from other pods.
- Tune for fast convergence rather than the WAN-scale defaults: 5 s registry fetch, 5 s heartbeat and 15 s lease expiry on clients; 5 s eviction sweep, read-only response cache off and self-preservation off on the server; 5 s LoadBalancer cache.

## Consequences

Positive:
- The same code and configuration run under compose and Kubernetes.
- Combined with the `preStop` drain to `OUT_OF_SERVICE` and connect-only retries ([ADR-010](ADR-010-retry-only-connection-failures.md)), rolling restarts are hitless. 0 failed requests were measured under load.
- `kubectl scale` works without any configuration change.

Negative:
- **Two discovery systems.** Kubernetes Services exist but aren't in the request path for gateway or Feign traffic, which surprises anyone debugging with k8s tooling.
- Eureka is an extra component, a single instance, and unauthenticated ([service-discovery](../services/service-discovery.md#known-issues-and-limitations)).
- After a restart the registry needs a few seconds to converge. During that window callers get `503 Load balancer does not contain an instance`, the most common false alarm in the [Runbook](../runbook.md).

## Related

[service-discovery](../services/service-discovery.md) · [k8s/README.md](../../k8s/README.md)
