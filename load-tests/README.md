# Load tests (k6)

Performance tests for the whole platform. They drive the API gateway the same way
`../smoke-test.sh` does, so routing, Eureka, JWT validation, the Feign hop to
product-service and the Kafka publish are all exercised under load.

| Script        | Traffic                                                              | Peak VUs (`load`) |
|---------------|----------------------------------------------------------------------|-------------------|
| `browse.js`   | anonymous reads: products, categories, product by id, catalog search | 50                |
| `checkout.js` | authenticated writes: create order → add item → confirm              | 10                |

Profiles (`PROFILE=`): `smoke` (1 VU, 30 s, the default; check the script works),
`load` (ramp to peak, hold 3 min), `stress` (ramp to 4× peak to find the breaking point).

```bash
./run-load.sh browse.js
PROFILE=load ./run-load.sh checkout.js
```

k6 runs in the `grafana/k6` container, so it needs only Docker and a running stack
(compose or k8s; both serve the gateway on `localhost:8080`). Each run writes
`reports/<script>-<profile>-<timestamp>/summary.{json,txt}`, and `reports/` is git-ignored.

Thresholds (the run exits non-zero if any fail): error rate < 1 %, checks > 99 %, and a p95
latency budget per tagged request. These budgets are starting points for a laptop stack.
Tighten them once you have a baseline from the target environment. Watch the Grafana dashboards
(`ecommerce-monitoring`) during `load`/`stress` runs to see which service saturates first.

`checkout.js` creates real users, products and orders. Run it against a disposable stack.
