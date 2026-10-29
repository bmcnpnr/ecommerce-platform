# ADR-003: MongoDB for the catalog read model

- **Status:** Accepted. It replaced the original PostgreSQL `catalogdb` on 2026-08-23.
- **Recorded:** 2026-10-29, reconstructed from the code, the catalog-service README and the compose and k8s comments.

## Context

catalog-service serves the storefront's browse and search views. Each entry is
a denormalised projection of one product from product-service, plus
merchandising fields that only the catalog owns (`featured`, `imageUrl`, an
overridable `price`). Its queries are all single-collection lookups: by product
ID, category, the featured flag, or name. There are no joins, no foreign keys
and no invariants spanning rows, and every write touches one entry.

## Decision

- Store the catalog in **MongoDB 8.0**: one document per product in the `catalog_entries` collection, with `_id` equal to the product ID.
- Keep the external JSON contract unchanged from the relational version (`id` is still present and always equals `productId`).
- Use Decimal128 for money, an `@Version` field for optimistic locking (a stale `PATCH` gets 409; the idempotent sync retries), and a weighted text index (name 10, brand 5, description 1) for relevance-ranked search. A case-insensitive substring match is the fallback for partial words.
- Keep the container, volume, StatefulSet and Service name `catalogdb`, so everything that addressed the old database keeps working. Only the engine and port (27017) changed.

## Consequences

Positive:
- The data model matches the access pattern: one read per page item, with no ORM mapping and no joins.
- Ranked full-text search comes built in.
- The platform shows a polyglot persistence example, with Mongo-specific monitoring (`mongodb-exporter-catalogdb`, `MongoDown` alert).

Negative:
- A second database technology to run, monitor and back up. The exporters and alerts had to be duplicated for Mongo.
- The catalog is only as fresh as its last `POST /api/v1/catalog/sync/{productId}`. Nothing pushes product changes to it automatically. See [catalog-service](../services/catalog-service.md).
- A one-time migration hazard: a `catalogdb-data` volume left over from Postgres must be dropped by hand.
- WiredTiger sizes its cache from the cgroup limit, so it must be pinned (`--wiredTigerCacheSizeGB 0.25`) to fit the 512 MB container.

## Related

[catalog-service](../services/catalog-service.md) · [Data model](../data-model.md) · [ADR-002](ADR-002-database-per-service.md)
