# ADR-013: Publish events through a transactional outbox

- **Status:** Accepted
- **Recorded:** 2026-10-30, with the resilience fixes ([resilience-fix-spec.md](../resilience-fix-spec.md) rule K4).

## Context

order-, payment- and shipping-service change a row in their own Postgres database and announce
the change on Kafka ([ADR-006](ADR-006-sync-queries-async-state-changes.md)). Kafka cannot take
part in a Postgres transaction, so every producer did a dual write, and each variant had its own
failure:

- order- and payment-service sent inside the database transaction, without waiting for the
  broker. With the broker down, `send()` blocked for `max.block.ms` (60 s) while the request held
  a pooled connection and then answered 500. If the commit failed after the send, the event
  described a change that never happened. If the asynchronous send failed after the commit, the
  event was lost: a paid order never got its shipment, or a cancelled one was still shipped.
- shipping-service committed the shipment and then sent the event. A crash or a broker blip between
  the two left a shipment without `shipment.created`, and the redelivered `payment.completed` saw
  the shipment and skipped it. Status changes sent before the commit, so a failed commit published
  a phantom `shipment.updated`.
- During a broker outage, about ten concurrent writes used up a 10-connection pool, and even
  unrelated reads, including the public tracking page, waited 30 s for a connection.

## Decision

- The service writes the serialized event into its own `outbox_event` table **in the same
  transaction** as the state change. It uses the same JSON mapper as before, so the bytes on the
  wire are unchanged (the Pact message tests pin them).

  ```sql
  CREATE TABLE outbox_event (
      id BIGSERIAL PRIMARY KEY, topic VARCHAR(255) NOT NULL, event_key VARCHAR(255),
      payload TEXT NOT NULL, created_at TIMESTAMP NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
      last_error VARCHAR(500), parked_at TIMESTAMP);
  CREATE INDEX idx_outbox_event_pending ON outbox_event (parked_at, id);
  ```

- `OutboxRelay` runs every 500 ms (`outbox.relay.interval-ms`). In one transaction it locks up to
  100 unparked rows, oldest first, with `FOR UPDATE SKIP LOCKED`. It sends each row
  (`acks=all`, idempotent producer), waits for the acknowledgement and deletes the row.
- A transient failure (broker down, timeout, database trouble) stops the batch, so the order is
  kept. It records `attempts` and `last_error` and pauses the relay from 1 s up to 30 s. It logs
  one WARN per minute while failing and one INFO on recovery.
- A permanent failure (record too large, invalid topic, serialization) parks that row
  (`parked_at`). The relay logs one ERROR with the SQL to release it
  (`UPDATE outbox_event SET parked_at = NULL WHERE id = ?`) and carries on with the next row.
- Delivery is at least once. Consumers are idempotent (rule K2), so a duplicate changes nothing.
- The three services carry their own copy of the same classes in `<base>.outbox`, because there is
  no shared code ([ADR-001](ADR-001-microservices-one-repo-each.md)). They use the same property
  names (`outbox.relay.enabled|interval-ms|batch-size|send-timeout-ms`) and the same metrics:
  `outbox_events_pending`, `outbox_events_parked`, `outbox_events_published_total` and
  `outbox_publish_failures_total`.

## Consequences

Positive:
- No event is lost or invented: the event exists exactly when the state change committed.
- A broker outage no longer reaches the request path. With Kafka frozen, a shipment PATCH returns
  in under 3 s, and both events arrive in order once Kafka is back.
- The backlog is measurable and alerted on (`OutboxEventsParked`, backlog growth, publish
  failures; see [observability.md](../observability.md)).

Negative:
- An event leaves up to about half a second after the commit.
- Duplicates are possible, for example after a crash between Kafka's acknowledgement and the
  delete, so every consumer has to stay idempotent.
- Per-key ordering holds for one relay. With several replicas, `SKIP LOCKED` lets two relays
  publish rows of the same key in parallel. Every producer runs one replica today.
- The relay holds a database connection while it waits for Kafka (`send-timeout-ms`, 35 s at
  most).
- A parked row waits for a person: it is alerted on, and the [runbook](../runbook.md) describes how
  to release it.
- Synchronous stock changes (order → product over Feign) are not events and are not covered.
  A timed-out stock call still has an unknown outcome.

## Related

[events.md](../events.md) · [ADR-006](ADR-006-sync-queries-async-state-changes.md) ·
[ADR-007](ADR-007-json-events-mirrored-classes.md) · [findings.md](../findings.md#resilience-findings-2026-10-30)
