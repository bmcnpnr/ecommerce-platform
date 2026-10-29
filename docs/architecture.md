# Architecture

An e-commerce platform built as a set of small Spring services behind an API
gateway, with a React storefront. Customers register, browse a product
catalogue, build a cart, check out with a simulated payment, get a shipment
with a tracking number, and review products. Administrators manage products,
categories, orders and reviews through the same API. The platform is also a
learning project. Its explicit goals are practising microservices, Kubernetes
and CI/CD, and that shows in a well-engineered runtime (discovery tuning,
contract tests, a full observability stack) next to business logic that is
still simple.

## System context

```mermaid
flowchart LR
    Shopper([Shopper]) -- browser --> P
    Admin([Administrator]) -- browser, admin pages --> P
    Dev([Developer / operator]) -- "Swagger UI, Grafana, kubectl" --> P
    P["Ecommerce platform<br/>(this system)"]
    P -. "simulated in payment-service" .-> PG[(Payment gateway)]
    P -. "logged by notification-service" .-> MAIL[(Email or SMS)]
```

Nothing outside the platform is called. The payment gateway is a random draw
inside payment-service, and notifications are log lines. Both are natural
integration points for later.

## Containers

```mermaid
flowchart TB
    subgraph Edge
        FE["frontend<br/>nginx + React SPA :3000"]
        GW["api-gateway :8080<br/>routing, JWT, Swagger UI"]
    end
    SD["service-discovery<br/>Eureka :8761"]
    subgraph Services
        US["user-service :8081"]
        PS["product-service :8082"]
        CS["catalog-service :8083<br/>(Kotlin)"]
        OS["order-service :8084"]
        PAY["payment-service :8085"]
        SH["shipping-service :8086"]
        RS["review-service :8087"]
        NS["notification-service :8088"]
    end
    subgraph Data
        UDB[(userdb)]
        PDB[(productdb)]
        CDB[("catalogdb<br/>MongoDB")]
        ODB[(orderdb)]
        PAYDB[(paymentdb)]
        SDB[(shippingdb)]
        RDB[(reviewdb)]
        K[("Kafka<br/>7 topics")]
    end
    FE -- "/api/**" --> GW
    GW --> US & PS & CS & OS & PAY & SH & RS
    OS -- Feign --> PS
    CS -- Feign --> PS
    RS -- Feign --> PS
    US --- UDB
    PS --- PDB
    CS --- CDB
    OS --- ODB
    PAY --- PAYDB
    SH --- SDB
    RS --- RDB
    OS & PAY & SH -- publish --> K
    K -- consume --> OS & SH & NS
    Services -. register .-> SD
    GW -. resolve .-> SD
```

Not drawn: the monitoring stack, which observes everything. It is Prometheus,
Grafana, Loki, promtail, Tempo and Alertmanager plus twelve exporters (18
containers), with Kafka UI alongside. See [Observability](observability.md).

## Service catalog

| Service | Responsibility | Store | Calls | Publishes | Consumes | Page |
|---|---|---|---|---|---|---|
| api-gateway | single entry point: routing, JWT validation, identity headers, CORS, retries, Swagger UI | — | every service | — | — | [api-gateway](services/api-gateway.md) |
| service-discovery | Eureka registry | memory | — | — | — | [service-discovery](services/service-discovery.md) |
| user-service | accounts, registration, login, JWT issuing, profiles | `userdb` | — | — | — | [user-service](services/user-service.md) |
| product-service | products, categories, stock (the source of truth) | `productdb` | — | — | — | [product-service](services/product-service.md) |
| catalog-service | denormalised storefront read model, search, merchandising flags | `catalogdb` (Mongo) | product-service | — | — | [catalog-service](services/catalog-service.md) |
| order-service | orders and lines, stock reservation, order lifecycle | `orderdb` | product-service | `order.placed`, `order.cancelled` | `payment.completed`, `payment.failed` | [order-service](services/order-service.md) |
| payment-service | payments, simulated gateway, refunds | `paymentdb` | — | `payment.completed`, `payment.failed`, `payment.refunded` | — | [payment-service](services/payment-service.md) |
| shipping-service | shipments, tracking numbers, delivery status history | `shippingdb` | — | `shipment.created`, `shipment.updated` | `payment.completed` | [shipping-service](services/shipping-service.md) |
| review-service | reviews, moderation, votes, rating summaries | `reviewdb` | product-service | — | — | [review-service](services/review-service.md) |
| notification-service | reacts to every business event (log lines today) | — | — | — | all seven topics | [notification-service](services/notification-service.md) |
| frontend | storefront, cart, checkout, tracking, admin pages | browser `localStorage` | api-gateway | — | — | [frontend](frontend.md) |

## Technology

| Area | Choice (version) |
|---|---|
| Language and runtime | Java 25 (Eclipse Temurin JRE, Alpine images). Kotlin 2.3.0 for catalog-service. |
| Framework | Spring Boot 4.0.1 (Spring Framework 7.0.2), Spring Cloud 2025.1.1 |
| Edge | Spring Cloud Gateway Server WebFlux 5.0.1 on Reactor Netty, JJWT 0.12.6 |
| Discovery and calls | Netflix Eureka 2.0.5, Spring Cloud LoadBalancer, OpenFeign 5.0.1 (feign-core 13.6, Apache HttpClient 5), resilience4j 2.3.0 (order-service) |
| Persistence | PostgreSQL 16 with Spring Data JPA 4.0.1, Hibernate 7.2 and Flyway 11.14. MongoDB 8.0 with Spring Data MongoDB 5.0.1 (driver 5.6.2). |
| Messaging | Kafka (Confluent cp-kafka 7.6.0, KRaft, one broker), spring-kafka 4.0.1 with kafka-clients 4.1.1, Jackson 3 JSON |
| JSON | Jackson 3.0.3 (REST and Kafka) |
| API docs | springdoc-openapi 2.8.5 (services, Spring MVC) and 3.0.3 (gateway, WebFlux UI) |
| Observability | Micrometer 1.16 with the Prometheus registry, OpenTelemetry 1.55 tracing to Tempo 2.5, Prometheus 2.52, Grafana 11.1, Loki 3.1 with promtail, Alertmanager 0.27 |
| Frontend | React 18, TypeScript 5.9, Vite 6, MUI 6.5, TanStack Query 5, zustand 5, axios, React Router 6, react-hook-form with zod, served by nginx 1.27 |
| Testing | JUnit 5, Mockito, Spring test slices, H2 2.4, Testcontainers 2.0.3, pact-jvm 4.7.5, Vitest 2 with MSW 2 |
| Delivery | Maven 3.9, Docker, Docker Compose, Kubernetes (Docker Desktop, Kustomize), CircleCI and GitHub Actions, Docker Hub |

## Design in brief

Each point is backed by an [architecture decision record](adr/README.md).

- **One repository, one database and one deployable per service** ([ADR-001](adr/ADR-001-microservices-one-repo-each.md), [ADR-002](adr/ADR-002-database-per-service.md)). No shared code and no cross-service joins. Data owned by another service arrives by API or event.
- **The catalog is a MongoDB read model** of product-service, refreshed on demand ([ADR-003](adr/ADR-003-mongodb-catalog-read-model.md)).
- **The gateway authenticates and the services trust its headers** ([ADR-004](adr/ADR-004-jwt-at-the-gateway.md)). Authorization was never added on top, which is the platform's largest gap ([Security](security.md)).
- **Client-side discovery with Eureka**, kept even on Kubernetes and tuned for hitless rollouts ([ADR-005](adr/ADR-005-eureka-client-side-discovery.md)).
- **Synchronous calls for lookups and stock, Kafka for state changes**, with the purchase saga choreographed by events ([ADR-006](adr/ADR-006-sync-queries-async-state-changes.md), [Communication](communication.md)).
- **JSON events without a schema registry.** Consumers keep mirror classes, and Pact pins every field ([ADR-007](adr/ADR-007-json-events-mirrored-classes.md), [ADR-008](adr/ADR-008-pact-without-broker.md)).
- **Retries only where a request provably never arrived**, meaning connect failures ([ADR-010](adr/ADR-010-retry-only-connection-failures.md)).
- **Metrics, logs and traces in one Grafana** ([ADR-011](adr/ADR-011-observability-stack.md)), and **one topology for compose and Kubernetes** ([ADR-012](adr/ADR-012-kubernetes-mirrors-compose.md)).

## Deployment

Both deployments run the same 38 workloads with the same names, ports and
credentials. Only one can run at a time on a machine, because both bind the
same localhost ports.

| | Docker Compose | Kubernetes |
|---|---|---|
| Definition | `ecommerce-platform/docker-compose.yml` | `ecommerce-platform/k8s/` (Kustomize), namespace `ecommerce` |
| Images | built locally from each repo's `docker/Dockerfile` | `ecommerce/<name>:local`, built by `k8s/build-images.sh` |
| Start-up order | `depends_on: condition: service_healthy` | busybox init containers that wait for each port |
| Health | wget on `/actuator/health` | startup and readiness on `/actuator/health/readiness`, liveness on `/actuator/health/liveness` |
| Exposure | every container port published on the host | `LoadBalancer` Services for the frontend, gateway, Eureka, databases and monitoring UIs. Service ports stay internal. |
| Memory | `mem_limit` per container (768 MB for most services), JVMs at `MaxRAMPercentage=55` | limits equal to compose, requests at about 40 % |
| Restarts | in place, with a few seconds of Eureka warm-up | rolling and hitless: `preStop` drains to `OUT_OF_SERVICE` for 15 s, then graceful shutdown |
| Docs | [Platform README](../README.md) | [k8s/README.md](../k8s/README.md) |

```mermaid
flowchart LR
    T1["Postgres x6, MongoDB, Kafka"] --> T2[service-discovery] --> T3["8 business services"] --> T4[api-gateway] --> T5[frontend]
```

A cold start takes 2 to 4 minutes, almost all of it JVM start-up under
contention.

## Build and delivery

- **Build locally.** Maven builds each service's jar on the host, and the Dockerfiles only copy it into a JRE image ([ADR-009](adr/ADR-009-runtime-only-images-prebuilt-jars.md)). `build-all.sh` and `rebuild.sh` (with PowerShell twins) orchestrate all ten repositories. The trap to know about: an image built without a fresh Maven build ships the old code.
- **CI** runs in each repository on every push and pull request, in three stages:
  1. **verify:** `mvn verify` with the tests and the Pact contracts.
  2. **validate-image:** a Docker build without registry credentials.
  3. **publish-image:** push to Docker Hub as `bmcnpnr/ecommerce-<name>`.
- **Publishing** happens only from trusted refs. `develop` publishes `develop` and `sha-<commit>`, `main` publishes `latest`, and `v*` tags publish the tag name.
- **CI providers:** ten repositories run CircleCI (`.circleci/config.yml`). Three (service-discovery, shipping-service, user-service) have moved to GitHub Actions (`.github/workflows/ci-cd.yml`) with the same three stages, using repository secrets instead of the CircleCI context. [CICD.md](../CICD.md) describes the CircleCI side.
- **Deploying published images:** `docker-compose.registry.yml` swaps the local builds for Docker Hub images. Nothing deploys automatically beyond that; continuous delivery stops at the registry.

## Testing strategy

| Layer | What | Where it runs | Size (2026-10-29) |
|---|---|---|---|
| Unit and slice | services with Mockito; controllers with `@WebMvcTest`; repositories on H2 (JPA) or real MongoDB via Testcontainers (catalog) | `mvn verify`, CI | 146 tests across nine services: gateway 4, user 18, product 23, catalog 36, order 21, payment 14, shipping 9, review 14, notification 7. Eureka has none. |
| Contract | Pact, consumer-driven: Feign calls, gateway identity headers, the JWT format, all seven event types | inside the same `mvn verify` | 10 pacts, 24 interactions ([ADR-008](adr/ADR-008-pact-without-broker.md)) |
| Frontend | components, stores, API client and pages with Vitest and MSW | `npx vitest run`, CI | 42 tests |
| End to end | 24 checks through the gateway: authentication, routing, Feign, MongoDB catalog, the Kafka round trip | `ecommerce-platform/smoke-test.sh` against compose or Kubernetes | 24 checks |

How each layer is wired:

- The JPA services' tests use H2 with `ddl-auto: create-drop` and Flyway disabled. The **Flyway migrations are never exercised by any test**; they first run when a real Postgres container starts.
- The catalog's MongoDB tests skip, rather than fail, when Docker isn't running.
- The Kafka tests use an embedded broker, so no test needs the stack.

There are no load tests, browser end-to-end tests or security tests. See
[Findings](findings.md) for the gaps that matter most.

## Quality attributes at a glance

| Attribute | State |
|---|---|
| Deployability | Strong: one command per environment, rolling restarts verified hitless on Kubernetes |
| Observability | Broad (metrics, logs, traces, 27 alert rules, 8 dashboards) but not joined up: traces stop at Feign and Kafka hops, and no alert is delivered anywhere ([Observability](observability.md)) |
| Contract safety | Strong: every cross-service interface is pinned by Pact. Proven on 2026-10-29, when the Kafka serializers were swapped for their Jackson 3 replacements and the pacts confirmed an unchanged wire format. |
| Security | Weak: authentication only, default credentials, most ports published ([Security](security.md)) |
| Data integrity | Weak across services: client-supplied payment amounts, unguarded state transitions, stock that leaks or can be inflated ([Flows](flows.md), [Findings](findings.md)) |
| Resilience | Partial: hitless restarts and connect-failure retries, but no outbox, no dead-letter topic, and inactive circuit breakers in two of three Feign callers |
| Scalability | Stateless services scale horizontally. Kafka consumers can't, because every topic has one partition. |
