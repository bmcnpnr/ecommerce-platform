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
| Grafana              | 3001 |
| Prometheus           | 9090 |

## Useful commands

```bash
docker compose logs -f               # tail all logs
docker compose logs -f user-service  # tail one service
docker compose ps                    # check health
docker compose down                  # stop (keep volumes)
docker compose down --volumes        # stop + wipe data
```
