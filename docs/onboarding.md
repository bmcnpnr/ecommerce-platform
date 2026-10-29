# Developer onboarding

From an empty machine to a running platform, then the everyday loop of
changing a service and seeing the change work. Read
[Architecture](architecture.md) alongside this guide; it explains what you are
starting.

## 1. Prerequisites

| Tool | Version | Why |
|---|---|---|
| JDK | 25 (Temurin or Oracle) | every Spring service targets Java 25 |
| Maven | 3.9.x | there is no Maven wrapper in the repositories |
| Docker Desktop | current, WSL2 backend on Windows | runs the stack. Give its VM **at least 8 GB** of memory; the stack idles around 4 GB, against ~14 GB of configured limits. |
| Node.js | 24 (matches `node:24-alpine` in the frontend Dockerfile) | only for frontend work outside Docker |
| Git Bash or WSL | — | `smoke-test.sh` and the other `.sh` scripts. PowerShell twins exist for build, rebuild and pact sync. |
| kubectl | optional | only for the Kubernetes deployment (Docker Desktop → Settings → Kubernetes) |

> **Use Git Bash, not PowerShell, for `curl` with JSON bodies.** PowerShell 5.1
> strips the double quotes from a JSON argument passed to `curl.exe`. The body
> arrives malformed and the resulting 400 looks like an application bug.

## 2. Get the code

The 13 repositories are independent Git projects that must sit side by side,
because `docker-compose.yml` builds from `../ecommerce-<name>`.

```bash
mkdir ecommerce && cd ecommerce
for r in platform service-discovery api-gateway user-service product-service catalog-service \
         order-service payment-service shipping-service review-service notification-service \
         frontend monitoring; do
  git clone https://github.com/bmcnpnr/ecommerce-$r.git
done
```

Active development happens on `develop` in every repository.

## 3. Build and start

The Dockerfiles copy a **prebuilt jar** from `target/`; nothing compiles inside
an image. Build with Maven first, or the image ships whatever jar was there
before.

```bash
cd ecommerce-platform
./build-all.sh --skip-tests        # Maven for all ten Spring repos, then docker compose build
docker compose up -d               # 38 containers
```

PowerShell: `.\build-all.ps1 -SkipTests`, then `docker compose up -d`.

A cold start takes **2 to 4 minutes**. Compose gates each tier on health
checks: databases and Kafka, then Eureka, then the services, then the gateway,
then the frontend. Early `unhealthy` states are normal. Wait for the gateway to
actually route:

```bash
until [ "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/api/v1/products)" = 200 ]; do sleep 5; done
./smoke-test.sh                    # 24 end-to-end checks through the gateway
```

## 4. Look around

| What | URL | Notes |
|---|---|---|
| Storefront | http://localhost:3000 | React SPA; nginx proxies `/api` to the gateway |
| API gateway | http://localhost:8080 | every API call goes here |
| Swagger UI, all services | http://localhost:8080/swagger-ui.html | pick a service from the dropdown, log in, Authorize, Try it out |
| Eureka | http://localhost:8761 | which instances are registered |
| Kafka UI | http://localhost:8090 | topics, messages, consumer groups and lag |
| Grafana | http://localhost:3001 | `admin` / `admin` by default; dashboards, Loki logs, Tempo traces |
| Prometheus | http://localhost:9090 | |
| Alertmanager | http://localhost:9093 | |
| Databases | Postgres on `localhost:5432`–`5438`, MongoDB on `localhost:27017` | credentials in `docker-compose.yml` |

## 5. Call the API by hand

```bash
GW=http://localhost:8080
U="dev$(date +%s)"
curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"email\":\"$U@example.com\",\"password\":\"Passw0rd!123\",\"firstName\":\"Dev\",\"lastName\":\"User\"}" \
  "$GW/api/v1/users/register"
TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"$U\",\"password\":\"Passw0rd!123\"}" "$GW/api/v1/users/login" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -H "Authorization: Bearer $TOKEN" "$GW/api/v1/users/me"
```

For the storefront's admin pages, log in as `admin` / `admin`. user-service
seeds that account on every start, and it is the only way an `ADMIN` exists.
It is fine locally and a finding everywhere else ([Security](security.md)).

Always go through the gateway. A direct call to a service port skips routing,
authentication and identity headers, so it proves less. The
[API reference](api/README.md) lists every endpoint, and
[End-to-end flows](flows.md) shows the order in which a real purchase calls
them.

## 6. The everyday loop

### Change one service and run it in Docker

```bash
cd ecommerce-order-service && mvn -B clean package -DskipTests && cd ../ecommerce-platform
docker compose up -d --build order-service
curl -s localhost:8084/actuator/health | grep -q PRODUCT-SERVICE && echo "peers visible"   # wait for Eureka
```

Use the **compose service name** (`order-service`), not the repo name. After a
restart, wait until Eureka has propagated the instance. Until then the gateway
answers `503 Load balancer does not contain an instance`, which is warm-up, not
a bug. If several services changed, `./rebuild.sh --skip-tests --keep-data`
does all of them.

### Run one service from the IDE against the Docker stack

Every service's `application.yaml` defaults point at `localhost` on the ports
compose publishes (`localhost:543x` for its Postgres, `localhost:27017` for
Mongo, `localhost:9092` for Kafka, `localhost:8761` for Eureka). That means a
plain IDE run connects to the compose infrastructure without any environment
variables:

1. `docker compose stop order-service`. This frees the port and lets the old registration expire, which takes about 15 s.
2. Run `OrderServiceApplication` from the IDE, with JDK 25 and no profile.
3. It registers in Eureka, and the gateway routes `/api/v1/orders/**` to it within a few seconds.

Because `prefer-ip-address` is on, the IDE instance registers your machine's IP
address, and the gateway container has to be able to dial it. If gateway calls
time out while the instance shows `UP` in Eureka, the registered IP is not
reachable from Docker. Start the service with
`--eureka.instance.ip-address=host.docker.internal`, which Docker Desktop
resolves to the host from inside containers.

### Debug a service inside Docker

Add a debug agent through a throwaway override file (not committed):

```yaml
# docker-compose.debug.yml
services:
  order-service:
    environment:
      JAVA_TOOL_OPTIONS: -agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005
    ports: ["5005:5005"]
```

```bash
docker compose -f docker-compose.yml -f docker-compose.debug.yml up -d order-service
```

Then attach a Remote JVM Debug configuration to `localhost:5005`.

### Frontend

```bash
cd ecommerce-frontend
npm ci
docker compose -f ../ecommerce-platform/docker-compose.yml stop frontend   # the container also uses port 3000
npm run dev                                                                  # http://localhost:3000, proxies /api to :8080
```

See [Frontend](frontend.md) for its structure and its API usage.

## 7. Tests

The [Testing guide](testing.md) covers each layer in depth: base classes, conventions and troubleshooting.

| Layer | Command | Needs |
|---|---|---|
| Unit and slice tests, one service (fast loop) | `mvn -B test` in the repo | nothing running, no Docker. H2 replaces Postgres and an embedded broker replaces Kafka. |
| Unit, integration and contract tests, one service | `mvn -B verify` in the repo | Docker, for the `*IT` classes: Testcontainers starts `postgres:16-alpine`, `cp-kafka:7.6.0` or `mongo:8.0`, with real Flyway migrations. Start Docker Desktop first: most ITs fail without it (only order-service's skip). No running stack. Run one IT with `mvn -B verify -Dit.test=OrderFlowIT` |
| All services | `./build-all.sh` (without `--skip-tests`) | Docker, as above |
| Frontend | `npx vitest run` (`npm run test:coverage` for coverage) | — |
| Frontend pacts | `npm run test:pact` in `ecommerce-frontend` | — |
| End to end | `./smoke-test.sh` | the running stack |
| Browser end to end | `npm run e2e:install` once, then `npm run e2e` in `ecommerce-frontend` | the running stack (`E2E_BASE_URL`, default `http://localhost:3000`). Report: `npm run e2e:report` |
| Load | `PROFILE=smoke ./run-load.sh browse.js` in `load-tests` (also `checkout.js`; profiles `smoke`, `load`, `stress`) | the running stack, Docker for the k6 image. `checkout.js` writes real data |
| Contracts across repos | `./sync-pacts.sh` | Node, for the frontend's pacts |

A test that finds a bug is **disabled, not deleted**: it asserts the correct behaviour and carries `@Disabled("BUG: ...")` (Java, Kotlin) or `it.fails` (frontend). When you fix a bug, remove the marker; for `it.fails`, the test turns red the moment the bug is fixed, which is the cue. The catalogue is [Findings](findings.md#bugs-pinned-by-tests).

If you change what a service **sends** or **expects** across a boundary (a Feign
call, a response field another service reads, a Kafka event), run
`./sync-pacts.sh`. Then commit the updated `src/test/resources/pacts/*.json` in
the provider repositories together with your change. The SPA's calls are pinned too: after changing an API
call in `ecommerce-frontend/src/api`, the same script regenerates `pacts/ecommerce-frontend-*.json` and copies
them into the providers (`pacts-frontend/` for order and payment). See
[Architecture: testing strategy](architecture.md#testing-strategy).

## 8. Conventions

- Package `com.ecommerce.<name>` with `config controller dto exception filter model repository service` (+ `client` for Feign, `event`/`kafka` for messaging).
- Every service: own database, own Flyway migrations (`src/main/resources/db/migration`), Eureka registration, actuator `health,info,metrics,prometheus,circuitbreakers,serviceregistry`, OpenTelemetry tracing to Tempo.
- Ports: gateway 8080, services 8081–8088, Eureka 8761. Databases on host ports 5432–5438 and 27017.
- REST paths are `/api/v1/<plural-resource>`. A new prefix needs a gateway route, and a public one needs an entry in `JwtAuthenticationFilter`.
- To add a new service, follow `.claude/skills/add-service/SKILL.md` (model it on product-service, or catalog-service for a Mongo read model).
- CI runs `mvn verify` on every push; images are published from `develop`, `main` and `v*` tags. See [Architecture: build and delivery](architecture.md#build-and-delivery).

## 9. Where to go next

- [Architecture](architecture.md): the big picture and why it looks the way it does.
- [Communication](communication.md) and [Event catalog](events.md): how the services talk.
- [End-to-end flows](flows.md): a purchase, step by step.
- [Service pages](README.md#services): one deep dive per service.
- [Runbook](runbook.md): when something is broken.
- [Architecture decisions](adr/README.md): why things are the way they are.
