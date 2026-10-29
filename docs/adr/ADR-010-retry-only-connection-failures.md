# ADR-010: Retry only on connection failures

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from the gateway configuration, `FeignConfig` in the Feign callers, and the k8s README.

## Context

During rolling restarts, callers kept dialling instances that had just been
terminated. Requests hung for the 30-second Netty connect timeout and then
failed with a 500. Retrying makes those requests succeed, but a blanket retry
policy is dangerous. A request that timed out while reading, or came back
with a 5xx, may already have been processed, and replaying a `POST` (create an
order, charge a payment) duplicates its effect.

## Decision

- Retry **only when the TCP connection could not be established.** The request never reached any instance, so replaying it is safe for every method.
- Gateway: a default `Retry` filter with 3 retries for `GET, POST, PUT, PATCH, DELETE`, on `java.net.ConnectException` only, with `series` and `statuses` emptied so 5xx responses are not retried, and exponential backoff from 100 ms to 1 s. Connect timeout 3 s.
- Feign (catalog-, order- and review-service): a `ConnectionFailureRetryer` in `FeignConfig` that retries only connection failures, with connect timeout 2 s. Each attempt goes back through the LoadBalancer, so it picks another instance.
- Read timeouts and 5xx are **never** retried automatically. Circuit breakers and fallbacks deal with persistent failure; see the service pages.

## Consequences

Positive:
- Together with fast Eureka convergence and the `preStop` drain ([ADR-005](ADR-005-eureka-client-side-discovery.md)), rollouts are invisible to callers.
- No risk of duplicate writes from automatic retries.

Negative:
- A transient read failure or a 503 from an overloaded instance is surfaced to the caller rather than hidden.
- Retry behaviour lives in two places, the gateway YAML and the Java `FeignConfig` in each caller, and has to be kept consistent by hand.

## Related

[Communication](../communication.md#client-configuration) · [api-gateway](../services/api-gateway.md#resilience)
