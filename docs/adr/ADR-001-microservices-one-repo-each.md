# ADR-001: Microservices, one repository per deployable

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from the code. The decision predates this record.

## Context

The project exists to build hands-on experience with microservices,
containers, Kubernetes and CI/CD (the original service READMEs say so). An
e-commerce domain splits naturally into users, products, catalog, orders,
payments, shipping, reviews and notifications, each with its own data and its
own rate of change.

## Decision

- Split the domain into eight business services plus three infrastructure components (API gateway, Eureka, frontend), each independently built, versioned and deployed.
- Give each one **its own Git repository**, plus `ecommerce-monitoring` for observability config and `ecommerce-platform` for orchestration: 13 repositories side by side, with no monorepo, submodules or shared library.
- Keep services uniform: same Spring Boot and Spring Cloud versions, same package layout, Dockerfile shape, actuator exposure and Eureka tuning. One service (catalog) is written in Kotlin, which shows the boundary is the HTTP and Kafka contract rather than the language.

## Consequences

Positive:
- Each service has its own CI pipeline, image and release cadence (`develop` → `develop` tag, `main` → `latest`, `v*` → version tag).
- Boundaries are enforced physically. A service can't reach into another's classes or tables.

Negative:
- **No shared code.** DTOs and event classes are duplicated on each side of a contract. notification-service keeps field-for-field mirrors of the producers' events, and a type drift between two copies caused the `shipment.created` poison-pill incident ([ADR-007](ADR-007-json-events-mirrored-classes.md)).
- Cross-repository changes need coordination. Contracts are protected by Pact files copied between repositories rather than by a compiler ([ADR-008](ADR-008-pact-without-broker.md)).
- Version alignment is manual. Every `pom.xml` pins the same parent and Spring Cloud versions, and drift has to be caught by eye.
- Local development needs all repositories checked out side by side, because `docker-compose.yml` builds from `../ecommerce-*`.

## Related

[Architecture](../architecture.md) · [Onboarding](../onboarding.md#2-get-the-code)
