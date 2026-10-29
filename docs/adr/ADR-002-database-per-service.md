# ADR-002: Database per service

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from the code. The decision predates this record.

## Context

Services that share a database end up coupled through its schema. One team's
migration breaks another service, and nothing stops a service from joining
across another's tables. Independent deployability ([ADR-001](ADR-001-microservices-one-repo-each.md))
needs independent data.

## Decision

- Every stateful service owns a private database that no other service connects to: `userdb`, `productdb`, `orderdb`, `paymentdb`, `shippingdb` and `reviewdb` on PostgreSQL 16, and `catalogdb` on MongoDB 8 ([ADR-003](ADR-003-mongodb-catalog-read-model.md)). notification-service is stateless.
- Each service manages its own schema with **Flyway** (`src/main/resources/db/migration`). Hibernate is not allowed to generate the production schema.
- Data owned by another service is obtained over its API (Feign) or from its events (Kafka). It is never read from the other service's tables.

## Consequences

Positive:
- A service's schema can change without touching any other repository.
- Each database can be sized, backed up and reset on its own ([Runbook](../runbook.md#reset-one-database)).

Negative:
- **No cross-service transactions or foreign keys.** An order references a product ID and a payment references an order ID, but nothing guarantees those IDs exist. Consistency across services is eventual and depends on events and compensations; see [ADR-006](ADR-006-sync-queries-async-state-changes.md) and [Data model](../data-model.md).
- Data is duplicated deliberately. For example, the catalog stores a copy of product fields and keeps it only as fresh as its last sync.
- Seven database containers and seven exporters cost memory locally (256 MB per Postgres, 512 MB for Mongo).
- Resetting one database leaves dangling references in the others. A consistent reset means wiping all of them.

## Related

[Data model](../data-model.md) · [Communication](../communication.md)
