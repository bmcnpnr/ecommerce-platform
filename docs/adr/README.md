# Architecture decision records

Short records of the decisions that shaped the platform: the context, what was
decided, and what it costs. They were **reconstructed on 2026-10-29** from the
code, its comments, the READMEs and the deployment files, so they describe
decisions as the code embodies them rather than as they were debated at the
time.

| ADR | Decision | Status |
|---|---|---|
| [ADR-001](ADR-001-microservices-one-repo-each.md) | Microservices, one repository per deployable | Accepted |
| [ADR-002](ADR-002-database-per-service.md) | Database per service, Flyway-managed schemas | Accepted |
| [ADR-003](ADR-003-mongodb-catalog-read-model.md) | MongoDB for the catalog read model | Accepted (replaced Postgres, 2026-08) |
| [ADR-004](ADR-004-jwt-at-the-gateway.md) | Authenticate at the gateway, pass identity as headers | Accepted; authorization incomplete |
| [ADR-005](ADR-005-eureka-client-side-discovery.md) | Client-side discovery with Eureka, also on Kubernetes | Accepted |
| [ADR-006](ADR-006-sync-queries-async-state-changes.md) | Synchronous calls for lookups and stock, Kafka events for state changes | Accepted |
| [ADR-007](ADR-007-json-events-mirrored-classes.md) | JSON events with mirrored classes, no schema registry | Accepted; error handling missing |
| [ADR-008](ADR-008-pact-without-broker.md) | Consumer-driven contract tests with Pact, without a broker | Accepted |
| [ADR-009](ADR-009-runtime-only-images-prebuilt-jars.md) | Runtime-only images built from prebuilt jars | Accepted |
| [ADR-010](ADR-010-retry-only-connection-failures.md) | Retry only on connection failures | Accepted |
| [ADR-011](ADR-011-observability-stack.md) | Prometheus, Loki and Tempo behind Grafana, with OpenTelemetry tracing | Accepted |
| [ADR-012](ADR-012-kubernetes-mirrors-compose.md) | Kubernetes manifests mirror the compose stack one-to-one | Accepted |

## Writing a new one

Copy any ADR, take the next number, and keep the four parts: **Context** (the
forces at play), **Decision** (what was chosen, stated as rules), and
**Consequences** (both the gains and the costs, honestly), plus **Related**
links. Never rewrite an accepted ADR to reflect a new decision. Add a new ADR,
and mark the old one `Superseded by ADR-0xx`.
