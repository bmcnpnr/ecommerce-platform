# ADR-007: JSON events with mirrored classes, no schema registry

- **Status:** Accepted. Serializers were migrated to Jackson 3 on 2026-10-29 with an unchanged wire format. Consumer error handling (dead-letter topics, back-off) was added on 2026-10-30.
- **Recorded:** 2026-10-29, reconstructed from the code, the Pact tests and the incident notes.

## Context

Services live in separate repositories with no shared library
([ADR-001](ADR-001-microservices-one-repo-each.md)), so producers and consumers
can't share event classes. A schema registry (Avro or Protobuf) would add
infrastructure and code generation to a small, local platform.

## Decision

- Event values are **JSON** written by spring-kafka's JSON serializer, **without type headers**. The consumer decides which class to bind to.
- Every consumer keeps its **own mirror class** of each event it reads. Unknown fields are ignored, so a mirror may hold a subset of the producer's fields.
- The record key is the **order ID** on every topic.
- `LocalDateTime` travels as an **integer array** `[y, M, d, H, m, s, nanos]`. This was the Jackson 2 default when the platform was built, and it is kept for compatibility.
- Compatibility is enforced by **Pact message contracts** instead of a registry. Every consumer pins the type of every field it reads, plus the key and topic ([ADR-008](ADR-008-pact-without-broker.md)).

### Revision, 2026-10-29: Jackson 3 serializers

spring-kafka 4.0 deprecated its Jackson 2 classes for removal: `JsonSerializer`,
`JsonDeserializer` and `JsonMessageConverter`. They were replaced as follows:

- **Producers** (order, payment, shipping) use `JacksonJsonSerializer`, passed to `DefaultKafkaProducerFactory` as an instance built with `.noTypeInfo()` and a mapper that enables `DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS`. Jackson 3 writes ISO strings by default, which would have silently changed the contract.
- **Consumers** use `JacksonJsonMessageConverter` (order, shipping) and `JacksonJsonDeserializer<T>` (notification). Jackson 3 reads both the array and the ISO form.

The unchanged provider and consumer pacts proved the wire format identical
before the change shipped, and raw records on the live cluster confirmed it.

### Revision, 2026-10-30: dead-letter topics and back-off

Every listener container (order, shipping, notification) now has a `DefaultErrorHandler`
([resilience-fix-spec.md](../resilience-fix-spec.md) rule K1):

- A record that cannot be converted, or keeps failing for a reason of its own, is retried twice a
  second apart and then published to `<topic>.DLT`; the partition moves on. order and shipping
  publish the value unchanged; notification-service re-serializes a listener failure from its
  mirror class, so that copy carries only the mirror's fields.
  notification-service also reads through an `ErrorHandlingDeserializer`, so an undecodable record
  never reaches `poll()` as an exception.
- A failure of the infrastructure behind the listener (database down, lock timeout, broker
  hiccup) is retried with back-off from 1 s to 30 s for as long as it lasts, so good events are not
  dead-lettered during an outage.
- The dead-letter write itself cannot loop. Copies never carry the stack-trace header, a copy that
  is still too large is retried bare (the record's own headers plus its origin), and a record the
  broker can never accept is skipped with one ERROR line. Before this, that case re-sent the
  record forever, writing about 100 stack-trace lines per second: the shape of the 992 GB
  incident.
- Producers write through a transactional outbox ([ADR-013](ADR-013-transactional-outbox.md)), so
  delivery is at least once and every listener is idempotent.

The wire format, the mirrored classes and the Pact contracts are unchanged.

## Consequences

Positive:
- No extra infrastructure. Messages are readable in Kafka UI and on the console.
- Additive changes are safe: new fields are ignored by consumers that don't know them.
- The contract tests make a breaking change fail a build. The Jackson 3 migration showed that they also catch accidental format changes.

Negative:
- **Nothing validates messages at the broker.** Any producer, or anyone with access to the plaintext broker, can publish any payload.
- **Duplicate classes drift.** A `LocalDate`-versus-`LocalDateTime` mismatch on `shipment.created` once made notification-service re-poll one record forever and write 992 GB of logs. The Pact contracts now cover every field, but…
- **…and a drifted or corrupt record is a failure every consumer has to survive.** Until 2026-10-30 that meant blocking (notification-service deserialized inside `poll()`) or losing the record silently (order and shipping). It now goes to `<topic>.DLT` after two retries, so it is kept but still needs a person to read and replay it. See [Event catalog: failure handling](../events.md#failure-handling).
- Integer-array dates are an unusual format that every non-Jackson consumer has to know about.

## Related

[Event catalog](../events.md) · [notification-service](../services/notification-service.md) · [Runbook: skip a poison pill](../runbook.md#skip-a-poison-pill)
