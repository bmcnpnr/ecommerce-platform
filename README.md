# ecommerce-platform

Central repository for running the full e-commerce microservices stack.

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

Three layers, fastest first. The first two need no running stack.

**Unit / slice tests (Maven, 67 tests across 7 services)** — H2 in place of Postgres,
`spring-kafka-test` for the messaging paths. `service-discovery`, `api-gateway` and
`notification-service` have context-load checks only.

```bash
./build-all.sh                 # runs tests; omit --skip-tests
cd ../ecommerce-user-service && mvn -B test      # or one service at a time
```

**Frontend tests (Vitest + MSW, 42 tests)** — component, store, API-client and page
tests with the network mocked at the request layer.

```bash
cd ../ecommerce-frontend
npm test              # watch mode
npx vitest run        # once, for CI
npm run test:coverage
```

The MSW handlers use **relative** URLs so they track `VITE_API_BASE_URL=/`. If you
switch the app back to an absolute base URL, the mocks must move with it or every
request falls through unmatched.

**End-to-end smoke test (19 checks)** — drives a running stack entirely through the
gateway, so it covers routing, Eureka discovery, JWT auth, the Feign hop into
product-service, and the Kafka publish, asserting notification-service actually
consumed the event.

```bash
docker compose up -d
./smoke-test.sh                       # waits for the gateway, then runs
GW=http://otherhost:8080 ./smoke-test.sh
```

Run it from Git Bash or WSL, **not PowerShell** — PowerShell 5.1 strips the double
quotes out of a JSON body passed to `curl.exe`, so requests arrive malformed and
the failures look like application bugs.

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
