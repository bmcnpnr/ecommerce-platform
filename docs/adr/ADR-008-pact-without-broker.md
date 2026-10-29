# ADR-008: Consumer-driven contract tests with Pact, without a broker

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from the code and the platform README.

## Context

With one repository per service ([ADR-001](ADR-001-microservices-one-repo-each.md))
and no shared DTO library, nothing at compile time stops a provider from
renaming a field a consumer reads, or from changing a type on the wire. An
end-to-end smoke test catches some of this, but only after deployment, and
only for the paths it exercises. A field-type drift on `shipment.created` once
put a consumer into an infinite failure loop in production-like conditions.

## Decision

- Pin every service-to-service interface with **consumer-driven contracts** (pact-jvm 4.7.5): 10 pacts and 24 interactions, covering the Feign calls into product-service, the gateway's identity headers into review- and user-service, the JWT claims user-service issues, and all seven Kafka event types.
- Consumer tests drive the **production** client code against a Pact mock: the real Feign client and `FeignConfig`, the real listener container on an embedded broker, or the real gateway filter. Provider tests replay the pacts against the **real** application: controllers and JPA on H2 over HTTP, or the real producer code with the production `JacksonJsonSerializer`. When the deprecated Jackson 2 serializers were replaced on 2026-10-29, these tests proved the wire format unchanged.
- Pact files are distributed as **committed files**, not through a Pact Broker. A consumer build writes `target/pacts/<consumer>-<provider>.json`, and `ecommerce-platform/sync-pacts.sh` regenerates all of them, copies them into each provider's `src/test/resources/pacts/` and verifies. Providers verify their committed copies on every `mvn verify`.
- Kafka message pacts include the record key and topic as metadata, and pin `LocalDateTime` in its wire form (an integer array).

## Consequences

Positive:
- A contract break fails the **other** side's build, before anything is deployed.
- No extra infrastructure: the tests are plain Surefire tests, so CI and `build-all` run them with no broker and no running stack.

Negative:
- Contract changes take a manual step: run `sync-pacts`, then commit the pact files in each provider repository along with the consumer change. Forgetting to do so makes the provider verify a stale contract.
- There is no can-i-deploy check and no record of which consumer version is deployed. Compatibility is only checked between the committed copies.
- Fixed mock-server ports (18082/18083/18087 for product-service's consumers, 18181/18187 for the gateway's) are needed because some Spring contexts are built before Pact starts. Running these tests in parallel on one machine would collide.

## Related

[Architecture: testing strategy](../architecture.md#testing-strategy) · [Event catalog](../events.md)
