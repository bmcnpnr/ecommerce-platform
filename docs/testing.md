# Testing guide

How to run, read and write every kind of test on the platform. For *what* each layer
covers and its size, see [Architecture: testing strategy](architecture.md#testing-strategy);
for the bugs the tests have found, see [Findings: bugs pinned by tests](findings.md#bugs-pinned-by-tests).

## The layers at a glance

| Layer | Lives in | Runs with | Needs |
|---|---|---|---|
| Unit and slice | `<repo>/src/test/**/*Test.java` (`.kt` in catalog) | `mvn test` | nothing (catalog's repository test: Docker) |
| Integration | `<repo>/src/test/**/integration/*IT.java` | `mvn verify` | Docker (not for the gateway and Eureka ITs) |
| Contract, service ↔ service | `<repo>/src/test/**/contract/*PactTest.java` | `mvn test` / `mvn verify`, or `./sync-pacts.sh` | nothing |
| Contract, frontend → services | `ecommerce-frontend/src/test/pact/*.pact.test.ts` | `npm run test:pact`, then each provider's `mvn verify` | nothing |
| Frontend unit | `ecommerce-frontend/src/test/**` | `npx vitest run`, `npm run test:coverage` | nothing |
| Smoke | `ecommerce-platform/smoke-test.sh` | `./smoke-test.sh` | running stack |
| Browser end to end | `ecommerce-frontend/e2e/` | `npm run e2e` | running stack |
| Load | `ecommerce-platform/load-tests/` | `./run-load.sh browse.js` | running stack, Docker |

`mvn test` is the fast inner loop. `mvn verify` is the whole suite and is what CI runs: Surefire
runs `*Test` in the `test` phase, then Failsafe runs `*IT` in `integration-test` and fails the
build in `verify`. Reports: `target/surefire-reports/` and `target/failsafe-reports/`.

## Everyday commands

```bash
# one service, everything (Docker Desktop running)
cd ecommerce-order-service && mvn verify

# one service, fast loop only
mvn test

# a single class or method
mvn test   -Dtest=OrderServiceTest
mvn verify -Dit.test=OrderFlowIT -Dtest=none -Dsurefire.failIfNoSpecifiedTests=false

# run the @Disabled bug tests to see them fail
mvn test -Djunit.jupiter.conditions.deactivate='org.junit.*DisabledCondition'

# all contracts: regenerate every pact (incl. the frontend's), copy, verify every provider
cd ecommerce-platform && ./sync-pacts.sh            # or .\sync-pacts.ps1
./sync-pacts.sh --verify-only                        # replay the committed pacts only

# frontend
cd ecommerce-frontend
npx vitest run            # unit and component tests
npm run test:coverage     # with coverage (v8)
npm run test:pact         # consumer contracts -> pacts/
npx tsc --noEmit

# load (stack up; see load-tests/README.md)
cd ecommerce-platform/load-tests && PROFILE=load ./run-load.sh checkout.js
```

## Conventions

- **Names decide the runner.** `*Test` is a unit or slice test; `*IT` is an integration test and
  must live in `com.ecommerce.<service>.integration`. A misnamed IT runs in the fast loop and
  drags Docker into `mvn test`.
- **Bugs stay in the suite.** A test that exposes a defect asserts the *correct* behaviour and is
  marked `@Disabled("BUG: <one line>")` (Java, Kotlin) or `it.fails(...)` (Vitest; Playwright uses
  `test.fail`). When you fix the bug, delete the marker. An `it.fails` test turns red by itself
  once the bug is fixed, so you can't forget. Each service page lists its disabled tests.
- **No production code changes for testability.** Tests use the code as shipped. Test-only
  configuration goes in `src/test/resources/application-it.yaml` (or the existing `test` profile).
- **Pin behaviour, not values.** Assert on what callers depend on: status, error body shape,
  the event that lands on the topic, the row in the database.

## Writing a unit or slice test

- Services: plain JUnit + Mockito (`@ExtendWith(MockitoExtension.class)`, `@Mock`, `@InjectMocks`), AssertJ.
- Controllers and error mapping: `@WebMvcTest(XController.class)` with `@MockitoBean` for the
  service. Spring Boot 4 moved the slice annotations: `@WebMvcTest` is
  `org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest`, and `@DataJpaTest` comes from
  the `spring-boot-data-jpa-test` module. Every `GlobalExceptionHandlerTest` drives the handler
  through a real controller this way, so the full error body (including `correlationId`) is checked.
- In services with Feign (`@EnableFeignClients` on the application class), slice tests also need a
  `@MockitoBean` for the Feign client, because the client bean is registered even in the slice.
- Jackson is version 3 (`tools.jackson.databind.*`).

## Writing an integration test

Every repository has a base class that starts the containers once per JVM and shares them across
IT classes (static singletons). Extend it rather than starting your own:

| Repository | Base | Containers / stubs |
|---|---|---|
| order-service | `ContainersBase`, `ApplicationTestBase` | Postgres, Kafka, WireMock (product-service) |
| payment-service | `AbstractIntegrationTest` | Postgres, Kafka |
| shipping-service | `AbstractIntegrationTest` | Postgres, Kafka |
| product-service | `PostgresIntegrationTestSupport` | Postgres |
| review-service | `PostgresIntegrationTestSupport` | Postgres, WireMock (product-service) |
| user-service | `PostgresContainerConfig` | Postgres |
| catalog-service | `AbstractCatalogIT` | MongoDB, WireMock (product-service) |
| notification-service | `AbstractKafkaIT` | Kafka |
| api-gateway | (`GatewayRoutingIT` itself) | one WireMock per route, no Docker |
| service-discovery | (`EurekaServerIT` itself) | none |

What the bases set up, and why:

- **Production images.** `postgres:16-alpine`, `confluentinc/cp-kafka:7.6.0` (as `ConfluentKafkaContainer`)
  and `mongo:8.0`, the same tags as `docker-compose.yml`. Testcontainers 2.x comes from the Boot-managed
  BOM; its artifacts carry the `testcontainers-` prefix (`testcontainers-postgresql`, `testcontainers-kafka`, ...).
- **Real schema.** Flyway runs the real migrations and Hibernate runs with `ddl-auto: validate`, so a
  mismatch between an entity and the migrations fails the build. This is the main reason the ITs exist:
  the H2 `test` profile builds the schema from the entities and has no foreign keys, which hid real failures.
- **Postgres and MongoDB** are wired with `@ServiceConnection`. **Kafka is not.** The services use plain
  spring-kafka with their own `KafkaProducerConfig`/`KafkaConsumerConfig` reading
  `spring.kafka.bootstrap-servers`, so nothing would consume the connection details. The bases set the
  property with `@DynamicPropertySource` instead.
- **Downstream HTTP** (product-service, for order, review and catalog) is a WireMock server
  (`org.wiremock:wiremock-standalone`, which bundles its own Jetty and doesn't clash with Boot 4), so the real
  Feign client, its retryer and its error decoding run. order-service registers the stub through Spring Cloud's
  simple discovery client; review and catalog point `spring.cloud.openfeign.client.config.product-service.url` at it.
- **Eureka and trace export are off** in `application-it.yaml`.
- **Without Docker** most container-backed ITs fail at startup. Only order-service's (`ContainersBase`) and
  catalog's repository test check for Docker and skip. Start Docker Desktop before `mvn verify`.

Patterns worth copying:

- **Asserting on Kafka.** Read what actually lands on the topic with a raw `KafkaConsumer` and compare it with
  the production serializer's output (`producerFactory.getValueSerializer()`), not hand-written JSON.
  Dates are int arrays on the wire (`[2026,10,29,13,45,7,123000000]`); see [Events: conventions](events.md#conventions-shared-by-every-topic).
- **Driving a consumer.** Publish the producer-shaped JSON (take it from the committed pacts) and wait with
  Awaitility for the database row or the `@MockitoSpyBean` call.
- **Random outcomes.** payment-service succeeds 80% of the time. The flow ITs keep initiating fresh payments
  until they get the outcome they need (up to 60 tries), rather than mocking the randomness.
- **Tests that can hang.** `PoisonPillIT` (notification-service) reproduces an infinite redelivery loop, so it
  has an Awaitility limit, a class `@Timeout` and `@DirtiesContext`. Do the same for anything that can loop.
- **catalog-service component scan.** The app's scan would pick up the Pact test's `FeignOnlyConfig` and register
  the Feign client twice; `AbstractCatalogIT` excludes it with a test-only filter.

## Writing a contract test

The model is unchanged from [ADR-008](adr/ADR-008-pact-without-broker.md): no broker; a consumer test writes
`target/pacts/<consumer>-<provider>.json` (frontend: `pacts/`), the provider keeps a committed copy and
verifies it in `mvn verify`, and `sync-pacts.sh` moves them. See [Communication](communication.md) and
[Events: contracts](events.md#contracts) for the service-to-service pacts.

**Frontend pacts.** `ecommerce-frontend` (pact-js, `vitest.pact.config.ts`, single fork) drives the real
`src/api` modules against the Pact mock server. Its README lists every provider state and the data each needs.

On the provider side, the frontend's requests arrive the way the browser sends them, **through the gateway**.
They carry `Authorization: Bearer <jwt>` (HS256 tokens signed with the dev secret, valid to 2100), but not the
identity headers the gateway adds. Each provider test therefore emulates the gateway: its `@TestTemplate` method
takes the outgoing `org.apache.hc.core5.http.HttpRequest`, decodes the token's payload (no signature check), and
sets `X-Username`, `X-User-Id` and `X-User-Role`. Paths are not rewritten. In pact-jvm 4.7.5
`@TargetRequestFilter` has no effect; use the method parameter.

| Provider | Verified in | Pact folder |
|---|---|---|
| user-service | `UserServiceProviderPactTest` | `pacts/` |
| product-service | `ProductServiceProviderPactTest` | `pacts/` |
| review-service | `ReviewServiceProviderPactTest` | `pacts/` |
| shipping-service | `FrontendHttpProviderPactTest` (`@Consumer("ecommerce-frontend")`); the message test is restricted with `@Consumer("notification-service")` | `pacts/` |
| order-service | `FrontendHttpProviderPactTest` | `pacts-frontend/` |
| payment-service | `FrontendHttpProviderPactTest` | `pacts-frontend/` |

order and payment use a separate folder because their `pacts/` holds only message pacts, which their message
provider tests load wholesale (payment's from three consumers, so a single `@Consumer` filter can't separate them).
`sync-pacts.sh` copies a frontend pact into `pacts-frontend/` when the provider has that folder, else into `pacts/`.
Provider state names are part of the contract: reuse an existing name verbatim and make its data satisfy every consumer.

## Frontend tests

Vitest with `jsdom`, Testing Library and MSW 2 (`src/test/mocks/handlers.ts`, `server.ts`).

- Render pages and components with `renderWithProviders` (router, query client, theme). Test hooks with
  `renderHook` and `createHookWrapper`. Build DTOs with the builders in `src/test/utils/fixtures.ts`.
- Override a handler per test with `server.use(...)`. Handler order matters in MSW: a specific route such as
  `/products/search` must come before `/products/:id`.
- Known bugs are `it.fails` with a comment naming the finding. None are open: M1, A-6, M4, M8 and A-7 to A-10 were fixed on 2026-10-29.
- The browser suite in `e2e/` is separate (Playwright); see [Frontend: end-to-end tests](frontend.md#end-to-end-tests-playwright).

## Load tests

`load-tests/browse.js` (anonymous reads) and `checkout.js` (create order → add item → confirm) drive the gateway in
the `grafana/k6` container. `PROFILE=smoke` (1 VU, 30 s) proves the script works; `load` holds the expected peak
(50 and 10 VUs); `stress` climbs to 4× peak. Thresholds (error rate < 1%, checks > 99%, a p95 budget per request)
make the run exit non-zero when they fail. Each run writes `load-tests/reports/<script>-<profile>-<time>/`.
`checkout.js` creates real users, products and orders, so point it at a disposable stack. Details: [load-tests/README.md](../load-tests/README.md).

## In CI

Every Java pipeline runs `mvn -B -ntp verify` with the Docker socket mounted, so the ITs run on every push and both
report folders are collected. The frontend pipeline runs `vitest` but not `test:pact`; regenerate frontend pacts locally
with `sync-pacts.sh`. Smoke, Playwright and load tests need a running stack and are manual or on demand. See [CI/CD](../CICD.md).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| ITs fail at startup with a Testcontainers "Could not find a valid Docker environment" error (order-service's are reported as skipped instead) | Docker isn't reachable. Start Docker Desktop. |
| `mvn verify` passes locally but runs no ITs | The class isn't named `*IT`, or the repository's pom lacks the Failsafe plugin. |
| Entity validation error at IT startup | The entity and the Flyway migrations disagree. Fix the migration (or the entity), not the test. |
| A provider pact fails after a consumer change | Expected: run `sync-pacts.sh`, add any new provider state, and commit the updated pact in the provider repo together with the consumer change. |
| A frontend pact fails with 401/403 at the provider | The gateway emulation didn't run: check that the `@TestTemplate` method still takes `HttpRequest` and sets the three headers. |
| A disabled BUG test now passes when run with `-Djunit.jupiter.conditions.deactivate=...` | The bug is fixed: remove `@Disabled` and update [Findings](findings.md). |
