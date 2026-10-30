# Resilience fix spec (2026-10-30)

Shared rules for removing points of failure across the 13 repos, written before the fixes and
corrected with what the implementation found (see [Lessons](#lessons-from-the-implementation)).
Every repo applies them the same way, so the platform fails the same way everywhere: loudly in
metrics, quietly in logs, and without losing state. The fixes are listed in
[findings.md](findings.md#resilience-findings-2026-10-30).

The incident that set the bar: on 2026-08-15 notification-service re-read one undeserializable
record in a tight loop, logged a stack trace per poll, wrote 992 GB of logs in 17 hours, filled the
Docker VM disk (a WSL2 vhdx never shrinks) and took Kubernetes down with DiskPressure. Any path that
can repeat that at request rate, poll rate or scheduler tick rate counts as a point of failure.

## L. Logging budget

- **L1** `logging.level.com.ecommerce: INFO` in every main `application.yaml`. DEBUG stays available
  through `LOGGING_LEVEL_COM_ECOMMERCE=DEBUG`.
- **L2** Lines written per read request are DEBUG. State changes stay INFO, one line per change.
- **L3** Catch-all handlers log ERROR with a stack trace once per failure site per 10 s, then count
  the rest and report them as `(N similar suppressed)` on the next line.
- **L4** A dead dependency is not a bug. Database (pool timeout, lock timeout, broken or frozen
  connection, a failed rollback or commit with a SQL cause), MongoDB, Kafka-timeout and peer
  "no answer" failures answer **503** `Service temporarily unavailable` and log one WARN without a
  stack trace per cause and 10 s, with the root cause in the line. Unique-constraint races and
  optimistic-lock conflicts stay 409. Hibernate's own JDBC error logger and Spring's
  `TransactionInterceptor` are `OFF`, because they repeat each failure with a full trace.
- **L5** Circuit breakers log state transitions (WARN on OPEN, INFO on CLOSED), never calls.
- **L6** Lines an anonymous client can trigger at request rate (bad JWTs, failed logins, unknown
  ids, rejected or duplicate Kafka events) are throttled the same way.
- **L7** `LogThrottle` is one identical class per Java service in `<base package>.logging` (no shared
  code, ADR-001), with `LogThrottleTest`. Catalog has a Kotlin copy with the same API. Reference
  copy: `ecommerce-order-service/src/main/java/com/ecommerce/order/logging/LogThrottle.java`.
  `acquire(key)` returns -1 inside a window, otherwise the number of suppressed calls; keys are
  capped at 256.
- **L8** One log pattern in every Java service, parsed by Promtail in compose and k8s:
  `%d{yyyy-MM-dd HH:mm:ss} [%thread] [%X{correlationId:-}] [%X{traceId:-}] %-5level %logger{36} - %msg%n`.

## K. Kafka

- **K1** Every listener container has a `DefaultErrorHandler`. Infrastructure failures (database,
  lock, broker) are retried with back-off from 1 s to 30 s for as long as they last, so good events
  are not dead-lettered during an outage. Anything else is retried twice, one second apart, and then
  published to `<topic>.DLT` (the original value; notification-service re-serializes a listener
  failure from its mirror class). The dead-letter recoverer (shipping's
  `kafka/DeadLetterRecoverer`, copied to notification and order) drops the stack-trace header, retries
  a bare copy on `RecordTooLargeException`, skips a record the broker can never accept with one ERROR,
  retries a transient DLT failure four times (1/2/4/8 s), and counts `kafka.dlt.published` and
  `kafka.dlt.dropped` per source topic.
- **K2** Listeners are idempotent: a duplicate event changes nothing and logs at most one INFO.
- **K3** All clients: `reconnect.backoff.ms` 1000, `reconnect.backoff.max.ms` 10000. Producers:
  `max.block.ms` 5000, `request.timeout.ms` 10000, `delivery.timeout.ms` 30000, `acks=all`,
  idempotence on.
- **K4** Transactional outbox in order-, payment- and shipping-service ([ADR-013](adr/ADR-013-transactional-outbox.md)):
  the event row (`outbox_event`) commits with the state change, and `OutboxRelay` publishes it every
  500 ms, oldest first. A row is deleted once Kafka acknowledges it. A transient failure stops the
  batch (keeping order) and backs off from 1 s to 30 s, with one WARN per minute and an INFO on
  recovery. A permanent failure parks the row with one ERROR containing the unpark SQL. Properties
  `outbox.relay.enabled|interval-ms|batch-size|send-timeout-ms`. Metrics: gauges
  `outbox_events_pending`/`outbox_events_parked` (refreshed by the relay every 5 s, never by a
  scrape) and counters `outbox_events_published_total`/`outbox_publish_failures_total`. Scheduled-task
  observations are excluded, so the relay creates no traces.

## H. HTTP and remote calls

- **H1** Feign: connect and read timeouts; a breaker named after the client (`product-service`,
  `order-service`) with 4xx ignored and slow-call opening (5 s, 80%); Spring Cloud CircuitBreaker's
  thread pool, TimeLimiter and bulkhead disabled, so the Feign timeouts govern; Apache HttpClient 5
  automatic retries disabled (R-6), so `ConnectionFailureRetryer` is the only retry; typed fallbacks
  (503 for no answer, 502 for a bad answer, 404 passed through).
- **H2** No remote call or CPU-heavy work (BCrypt) inside a database transaction. A non-idempotent
  call (stock deltas) that times out is not repeated.
- **H3** Gateway: `httpclient.response-timeout` 20 s (above the services' Feign read timeouts of
  5-10 s, below the SPA's 30 s and nginx's 35 s); pool `max-idle-time` 20 s (below Tomcat's 60 s
  keep-alive), `max-life-time` 5 m; a 1 MB body cap in a `WebFilter` ahead of the gateway plus the
  `RequestSize` filter; `server.netty.idle-timeout` 2 m; `-XX:MaxDirectMemorySize=128m`.

## D. Data stores

- **D1** Hikari `connection-timeout` 5000; pgjdbc `connectTimeout` 5, `socketTimeout` 30,
  `tcpKeepAlive` true; `spring.jpa.open-in-view: false`.
- **D2** Pessimistic locks carry `jakarta.persistence.lock.timeout` 5000; a lock timeout is a 503.
- **D3** Lists are bounded. List endpoints keep returning JSON arrays, take optional `page`/`size`
  (default and maximum 100), and the SPA fetches further pages on "Show more".
- **D4** MongoDB: server selection 3 s, connect 2 s, socket 5 s, pool wait 2 s, `maxTimeMS` 4 s on
  searches; the catalog starts without MongoDB and initialises in the background.

## P. Platform

- **P1** Every store has a size bound: Prometheus `retention.size` 5 GB and `sample_limit` 50000,
  Kafka `log.retention.bytes` 128 MiB per partition with 32 MiB segments, Loki 0.5 MB/s per tenant
  and 128 KB/s per stream, Tempo 1 MB/s, Promtail 300 lines/s per container, Docker logs 50 MB × 3
  in non-blocking mode. Compose and k8s stay mirrors (ADR-012), enforced by parity scripts.
- **P2** Alerts for log rate and error-log rate, Promtail shedding, Loki and Tempo discards, DLT
  records, floods and drops, stuck consumers, outbox backlog and parked rows, connection-pool
  timeouts, and disks that will fill within 4 or 24 hours. `promtool` unit tests run in CI.
- **P3** Promtail parses L8 in compose and k8s, groups stack traces into one entry and drops DEBUG.
- **P4** JVMs exit on OOM and never write heap dumps: `-XX:+ExitOnOutOfMemoryError
  -XX:-HeapDumpOnOutOfMemoryError` for the Spring services, `-XX:+ExitOnOutOfMemoryError` for Kafka
  and kafka-ui (heap dumps are off by default there).

## F. Frontend

- **F1** A render error never blanks the app: a top-level boundary, a boundary around every routed
  page, and lazy chunks that reload once after a redeploy.
- **F2** No request storms: 4xx is never retried, network and 5xx errors at most once with jitter,
  mutations never; no polling; double submits are blocked; no redirect loop on 401.
- **F3** Corrupt or blocked `localStorage`/`sessionStorage` resets instead of crashing.

## T. Tests and process

Every fix ships with a test that asserts the correct behaviour, in the repo's style (see
[testing.md](testing.md)). Log volume is asserted by counting events with a Logback `ListAppender`
(for example 100 failing requests → at most 2 lines). `mvn -B verify` passes in every Java repo, and
`npm test`, `npm run build` and `npm run test:pact` pass in the frontend with the pact files unchanged.

## Lessons from the implementation

The first version of these rules missed the following. Each one was measured before it was fixed.

| Lesson | What happened |
|---|---|
| Spring Cloud CircuitBreaker defaults | Enabling the Feign breaker also enabled a 1 s TimeLimiter and a thread-pool bulkhead of one thread per CPU: slower calls failed, and the fallback received `ExecutionException(FeignException)`, so 404 checks stopped matching. Disable the thread pool, TimeLimiter and bulkhead. |
| A dead letter that cannot be written | If the DLT copy (value plus exception headers) exceeds `max.request.size`, the recoverer throws and Spring retries recovery immediately, logging a trace each time, forever. Measured in notification-service: ~100 stack-trace lines per second. That is the 992 GB incident again. |
| Hibernate and transaction loggers | Hibernate writes 2 WARN lines per failed JDBC call; a killed connection made `TransactionInterceptor` log a trace of ~560 lines and turned the response into a 500. |
| open-in-view | With Boot's default, the first query's connection stays checked out until the response is written, even without a transaction. |
| pgjdbc socket timeout | The driver has none: a database that stops answering holds threads for minutes. Hikari's timeout only bounds acquiring a connection. |
| Gateway body buffering | The `Retry` default filter caches every request body before authentication and before `RequestSize`: an anonymous POST declaring 300 MB got no answer. The cap has to be a `WebFilter`. |
| Keep-alive | Tomcat's keep-alive is 60 s, not 30 s; the gateway's pool idle time (20 s) is below both. |
| Scheduled-task tracing | Spring observes every `@Scheduled` run: a 500 ms relay creates ~170k traces a day at 100% sampling. |
| Test clients | The Apache client behind `RestTestClient` re-sends a 503 and honours `Retry-After`; ITs that count requests use the JDK `HttpClient`. |
| Promtail filtering | A relabel `keep` in Promtail 3.1 still tails the dropped containers and ships them without labels; Loki rejected every batch and Promtail logged an error about once a second. |
