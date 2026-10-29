# ecommerce-platform

Central repository for running the full e-commerce microservices stack.

## Documentation

**[docs/](docs/README.md)** is the documentation hub for the whole platform:

- [architecture](docs/architecture.md), [communication](docs/communication.md) and [end-to-end flows](docs/flows.md);
- one deep dive per service under [docs/services/](docs/services/);
- the [API reference](docs/api/README.md) with generated [OpenAPI files](docs/api/openapi/), and the Kafka [event catalog](docs/events.md);
- the [data model](docs/data-model.md), [security](docs/security.md) and [observability](docs/observability.md);
- the [onboarding guide](docs/onboarding.md) and [runbook](docs/runbook.md);
- [architecture decisions](docs/adr/README.md), and [findings and a roadmap](docs/findings.md).

Every API can be tried from one Swagger UI at http://localhost:8080/swagger-ui.html
once the stack is up. `./export-openapi.sh` regenerates the committed OpenAPI
files from a running stack.

To get all of it as one navigable PDF (contents page and bookmarks), run
`cd docs-pdf && npm install && npm run build`. The output is
`dist/ecommerce-platform-documentation.pdf`, and `npm run watch` rebuilds it as
the docs change.

## Repository layout

```
parent-dir/
├── ecommerce-platform/           ← this repo
├── ecommerce-service-discovery/
├── ecommerce-api-gateway/
├── ecommerce-user-service/
├── ecommerce-product-service/
├── ecommerce-catalog-service/
├── ecommerce-order-service/
├── ecommerce-payment-service/
├── ecommerce-shipping-service/
├── ecommerce-review-service/
├── ecommerce-notification-service/
└── ecommerce-frontend/
```

## Build & run

The Dockerfiles copy a **pre-built jar** from each service's `target/`; they do
not compile inside the image. Always run the Maven build before building images,
or the image will silently package the previous jar.

```bash
# Build all services + Docker images, then start
./build-all.sh --skip-tests
docker compose up -d

# Or do everything in one shot (stops stack, full rebuild, starts)
./rebuild.sh --skip-tests
```

PowerShell:
```powershell
.\build-all.ps1 -SkipTests
docker compose up -d

# Or:
.\rebuild.ps1 -SkipTests
```

## Flags

`build-all.sh` / `build-all.ps1`:

| Flag (bash)    | Flag (PS)    | Effect                                      |
|----------------|--------------|---------------------------------------------|
| `--skip-tests` | `-SkipTests` | Skip Maven unit tests                       |
| `--no-docker`  | `-NoDocker`  | Maven only — skip Docker image rebuild      |
| `--no-cache`   | `-NoCache`   | Pass `--no-cache` to `docker compose build` |

`rebuild.sh` / `rebuild.ps1`:

| Flag (bash)    | Flag (PS)    | Effect                                     |
|----------------|--------------|--------------------------------------------|
| `--skip-tests` | `-SkipTests` | Skip Maven unit tests                      |
| `--keep-data`  | `-KeepData`  | Preserve named volumes (database data)     |
| `--no-up`      | `-NoUp`      | Build images but do not start containers   |

## Testing

Seven layers. The unit, integration, frontend and contract tests need no running stack; the smoke, browser and load tests do.

**Unit / slice tests (Maven, Surefire `*Test`)** — 716 tests. Mockito services,
`@WebMvcTest` controllers, `GlobalExceptionHandler`, `CorrelationIdFilter`, Kafka
producers and consumers, Feign fallbacks and retryers, and the gateway's
`JwtAuthenticationFilter` and `CorsConfig`. H2 stands in for Postgres in the JPA slices and
`spring-kafka-test` for the broker. Only `service-discovery` has no unit tests.
`catalog-service` (MongoDB) also runs its repository against a real
`mongo:8.0` via Testcontainers; those tests are skipped, not failed, when no
Docker daemon is reachable.

**Integration tests (Maven, Failsafe `*IT`)** — 195 tests in every Maven repository,
package `<base>.integration`, run by `mvn verify`. Each boots the whole service
(`@SpringBootTest(RANDOM_PORT)`) against the **production images** in Testcontainers 2.x:
`postgres:16-alpine`, `confluentinc/cp-kafka:7.6.0` and `mongo:8.0`. Flyway really runs and
Hibernate uses `ddl-auto: validate`, so schema drift fails the build; the H2 test profile has no
foreign keys, for example. They drive HTTP to database to Kafka flows and stub Feign
downstreams with WireMock 3.13.1. The gateway IT puts a WireMock behind every route, and
`EurekaServerIT` boots the registry. Container-backed ITs need Docker and fail without it (only order-service's skip).

```bash
./build-all.sh                 # runs mvn verify (unit + integration + pact); omit --skip-tests
cd ../ecommerce-user-service && mvn -B test      # unit tests only, the fast loop
cd ../ecommerce-user-service && mvn -B verify    # plus the *IT classes (needs Docker)
```

**Bugs found by tests stay in the suite**, disabled. A test that finds a defect asserts the
correct behaviour and carries `@Disabled("BUG: ...")` (Java, Kotlin) or `it.fails` (frontend).
Remove the marker in the change that fixes the bug. Catalogue: `docs/findings.md`, "Bugs pinned by tests".

**Frontend tests (Vitest + MSW, 391 tests)** — component, hook, store, API-client
(including the axios interceptors), page and validator tests with the network mocked at the
request layer, at about 99% of lines, 93% of functions and 92.6% of branches
(`@vitest/coverage-v8`). Known bugs are `it.fails` tests.

```bash
cd ../ecommerce-frontend
npm test              # watch mode
npx vitest run        # once, for CI
npm run test:coverage
npm run test:pact       # frontend consumer pacts, see Contract tests below
```

The MSW handlers use **relative** URLs so they track `VITE_API_BASE_URL=/`. If you
switch the app back to an absolute base URL, the mocks must move with it or every
request falls through unmatched.

**End-to-end smoke test (24 checks)** — drives a running stack entirely through the
gateway, so it covers routing, Eureka discovery, JWT auth, the Feign hop into
product-service, the MongoDB-backed catalog sync/read-back, and the Kafka publish,
asserting notification-service actually consumed the event.

```bash
docker compose up -d
./smoke-test.sh                       # waits for the gateway, then runs
GW=http://otherhost:8080 ./smoke-test.sh
```

**Browser end-to-end tests (Playwright, 26 tests)** — live in `ecommerce-frontend/e2e`
and drive the real SPA in Chromium against a running stack: sign-up and login,
search, cart, checkout through payment and Kafka, cancel, tracking and the admin
pages. Each test seeds its own data, so the suite is safe to run in parallel and
against a shared environment.

```bash
cd ../ecommerce-frontend
npm run e2e:install                   # once: Chromium
npm run e2e                           # against http://localhost:3000
E2E_BASE_URL=https://staging.example.com npm run e2e
scripts/e2e-docker.sh                 # in the Playwright image, for agents without Node
```

Every run writes an HTML report (traces, screenshots and videos of failures),
JUnit XML and a Markdown summary to `reports/`. See `ecommerce-frontend/e2e/README.md`.

Run the smoke test from Git Bash or WSL, **not PowerShell** — PowerShell 5.1 strips the double
quotes out of a JSON body passed to `curl.exe`, so requests arrive malformed and
the failures look like application bugs.


**Load tests (k6)** — `load-tests/` drives the gateway with `browse.js` (anonymous reads) and
`checkout.js` (create order, add item, confirm) in the `grafana/k6:0.54.0` container, so it
needs only Docker and a running stack. Profiles `smoke` (default), `load` and `stress`, with
error-rate, check and per-request p95 thresholds; each run writes `reports/<script>-<profile>-<timestamp>/`.
Manual: no pipeline runs it, and `checkout.js` creates real data, so use a disposable stack.

```bash
cd load-tests
./run-load.sh browse.js
PROFILE=load ./run-load.sh checkout.js
```

See `load-tests/README.md`.

**Contract tests (Pact, 24 service-to-service interactions across 10 pacts, plus 40 frontend
interactions across 6)** — pin every
service-to-service interface and every call the SPA makes so a change on one side fails the *other* side's build
instead of production. Consumer-driven with [pact-jvm](https://docs.pact.io/implementation_guides/jvm)
4.7.5: each consumer owns a `*ConsumerPactTest` that exercises its **real** client
code (the production Feign client and `FeignConfig`, or the production Kafka listener
container via an embedded broker) against a Pact mock and records what it sends and
which response/event fields it relies on; each provider owns a `*ProviderPactTest`
that replays those pacts against the **real** application (controllers + JPA on H2
over HTTP, or the real service/producer code serialized with the production Kafka
`JacksonJsonSerializer`). Both run as ordinary Surefire tests, so `mvn verify`, CI and
`./build-all.sh` already execute them — no broker and no running stack.

**Frontend pacts.** The React SPA is a consumer too. `npm run test:pact` (pact-js
`@pact-foundation/pact` 17.1.4) drives the real `src/api/*` modules and axios interceptors against a
Pact mock server and writes `ecommerce-frontend/pacts/ecommerce-frontend-<provider>.json` for six
providers: user (6 interactions), product (11), order (7), payment (4), shipping (4), review (8).
The SPA talks to the gateway, so each provider verifies with **gateway emulation**: the test decodes
the bearer token and sets `X-Username` / `X-User-Id` / `X-User-Role`. user, product and review
extended their existing provider test. order and payment verify from
`src/test/resources/pacts-frontend/` (`FrontendHttpProviderPactTest`) because their `pacts/` holds
message pacts only; shipping uses `FrontendHttpProviderPactTest` with `@Consumer` filters in `pacts/`.

| Consumer → Provider | Transport | What is pinned |
|---|---|---|
| order-service → product-service | Feign | `GET /api/v1/products/{id}`, `PATCH /api/v1/products/{id}/stock` (`{"delta":n}`), 404 / 400 error shape |
| catalog-service → product-service | Feign | `GET /api/v1/products/{id}` (all fields the Kotlin DTO needs), `GET /api/v1/categories`, 404 |
| review-service → product-service | Feign | `GET /api/v1/products/{id}` existence check, 404 |
| api-gateway → review-service | HTTP | `X-Username` / `X-User-Id` / `X-User-Role` headers injected after JWT validation |
| api-gateway → user-service | HTTP + JWT | the same headers on `/api/v1/users/me`; the JWT claims user-service signs (`sub`, numeric `userId`, `role`, HS256/384/512) |
| order-service ← payment-service | Kafka | `payment.completed`, `payment.failed` |
| shipping-service ← payment-service | Kafka | `payment.completed` |
| notification-service ← order-service | Kafka | `order.placed`, `order.cancelled` |
| notification-service ← payment-service | Kafka | `payment.completed`, `payment.failed`, `payment.refunded` |
| notification-service ← shipping-service | Kafka | `shipment.created`, `shipment.updated` |

Kafka events travel as spring-kafka `JacksonJsonSerializer` output — note that `LocalDateTime`
fields are **integer arrays** (`[y, M, d, H, m, s, nanos]`), not ISO strings; the pacts
pin that form. Jackson 3 would write ISO strings by default, so each producer's
`KafkaProducerConfig.eventJsonMapper()` switches on `DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS`
to keep the format the deprecated Jackson 2 `JsonSerializer` produced. Record key (`orderId`) and topic are part of each message's metadata.

The repositories are independent Git projects and there is no Pact broker, so the
pact files are the hand-off: a consumer test writes `target/pacts/<consumer>-<provider>.json`,
the provider keeps a committed copy in `src/test/resources/pacts/` and verifies it on
every build. After changing a consumer's expectations run

```bash
./sync-pacts.sh                 # regenerate all pacts (incl. the frontend's), copy into providers, verify
./sync-pacts.sh --verify-only   # replay the committed pacts against every provider
.\sync-pacts.ps1                # PowerShell twin (-NoVerify / -VerifyOnly)
```

and commit the updated `src/test/resources/pacts/*.json` (and `pacts-frontend/*.json`, where that
folder exists) in the provider repositories
together with the consumer change. A provider build that fails its `*ProviderPactTest`
means that provider would break the named consumer; fix the provider or, if the change
is intended, update the consumer and re-sync.

## Service ports

| Service              | Port |
|----------------------|------|
| Frontend             | 3000 |
| API Gateway          | 8080 |
| Eureka Dashboard     | 8761 |
| User Service         | 8081 |
| Product Service      | 8082 |
| Catalog Service      | 8083 |
| Order Service        | 8084 |
| Payment Service      | 8085 |
| Shipping Service     | 8086 |
| Review Service       | 8087 |
| Notification Service | 8088 |
| Kafka UI             | 8090 |
| Grafana              | 3001 |
| Prometheus           | 9090 |
| Alertmanager         | 9093 |
| Loki                 | 3100 |
| Tempo                | 3200 |

Grafana signs in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`
(default `admin` / `admin`), overridable via `ecommerce-platform/.env`.

## Databases

One database per service. Six are PostgreSQL; `catalogdb` is **MongoDB**, because
catalog-service keeps a join-free read model of product-service (one document per
product, keyed by product id — see `ecommerce-catalog-service/README.md`).

| Database   | Engine            | Host port | Service          |
|------------|-------------------|-----------|------------------|
| userdb     | postgres:16       | 5432      | user-service     |
| productdb  | postgres:16       | 5433      | product-service  |
| orderdb    | postgres:16       | 5434      | order-service    |
| catalogdb  | **mongo:8.0**     | **27017** | catalog-service  |
| paymentdb  | postgres:16       | 5436      | payment-service  |
| shippingdb | postgres:16       | 5437      | shipping-service |
| reviewdb   | postgres:16       | 5438      | review-service   |

```bash
docker compose exec catalogdb mongosh -u cataloguser -p catalogpass --authenticationDatabase admin catalogdb
```

If `catalogdb-data` was created by the former Postgres catalogdb it holds files
Mongo cannot use — drop it once with `docker compose down --volumes` (or
`rebuild.ps1` without `-KeepData`). Every metric exporter follows the engine:
`postgres-exporter-<db>` for the six Postgres databases, `mongodb-exporter-catalogdb`
(percona/mongodb_exporter, :9216) for Mongo.

## Resource limits

Every container sets `mem_limit`, and the JVM services get
`-XX:MaxRAMPercentage=55 -XX:ActiveProcessorCount=2` through `JAVA_OPTS`. Both
halves matter: without a `mem_limit` each JVM sizes its heap against the whole
Docker VM (~4 GB max heap each, ten times over), and with a limit but no
`MaxRAMPercentage` the JVM default of 25% leaves too little heap. The stack
idles around 4 GB against roughly 14 GB of configured ceilings.

## Useful commands

```bash
docker compose logs -f               # tail all logs
docker compose logs -f user-service  # tail one service
docker compose ps                    # check health
docker compose down                  # stop (keep volumes)
docker compose down --volumes        # stop + wipe data
```
