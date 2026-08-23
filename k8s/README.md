# Kubernetes deployment

The same 38 workloads as `docker-compose.yml`, as 8 StatefulSets, 27 Deployments
and 3 DaemonSets. Service names, ports and credentials are identical to the
compose stack, which is why every monitoring config file could be reused
byte-for-byte.

```
00-namespace.yaml            namespace: ecommerce
01-secrets.yaml              JWT, Grafana and the seven database credentials
02-config.yaml               the java-env ConfigMap (x-java-env from compose)
05-monitoring-config.yaml    GENERATED from ../../ecommerce-monitoring
10-databases.yaml            7 database StatefulSets, one per service: 6 postgres + MongoDB for catalogdb
20-kafka.yaml                single-node KRaft broker
30-service-discovery.yaml    Eureka
40-services.yaml             8 Spring services + the API gateway
50-frontend.yaml             nginx SPA, with a Kubernetes-specific proxy config
60-monitoring.yaml           Prometheus, Alertmanager, Loki, Tempo, Grafana, Promtail
70-exporters.yaml            node-exporter, cAdvisor, Kafka exporter + UI, blackbox, nginx
71-postgres-exporters.yaml   one exporter per Postgres database
72-mongodb-exporters.yaml    mongodb_exporter for catalogdb
```

## Deploying

Prerequisite: Kubernetes enabled in Docker Desktop (Settings → Kubernetes →
Enable Kubernetes). `kubectl config current-context` should print
`docker-desktop`.

Docker Desktop offers two cluster provisioners and this deployment works on
both, but they are not identical — a Docker Desktop upgrade can switch you from
one to the other, which replaces the cluster with an empty one:

| | kubeadm | kind |
|---|---|---|
| node name | `docker-desktop` | `desktop-control-plane` |
| runtime | cri-dockerd | containerd |
| `type: LoadBalancer` | binds on localhost | binds on localhost |
| locally built images | shared | pulled from Docker on demand; a rebuilt tag needs `crictl pull` on the node (build-images does it) |
| promtail stage | `docker: {}` | `cri: {}` |
| kubelet log rotation | no | yes (10 MB × 5) |

`docker desktop kubernetes status` prints the active mode. Only the promtail
pipeline stage in `60-monitoring.yaml` has to match — everything else is
portable between the two.

```powershell
..\build-all.ps1 -SkipTests    # Maven; the Dockerfiles copy a pre-built jar
.\build-images.ps1             # docker build + tag as ecommerce/<name>:local
.\deploy.ps1                   # kubectl apply -k . and wait for rollout
```

The Bash equivalents (`../build-all.sh`, `./build-images.sh`, `./deploy.sh`) are
identical in behaviour.

Skipping the Maven step ships the previous jar and looks exactly like "my fix
did not apply", so `build-images` refuses to run when a `target/*.jar` is
missing.

| | |
|---|---|
| Frontend | http://localhost:3000 |
| API gateway | http://localhost:8080 |
| Eureka | http://localhost:8761 |
| Grafana | http://localhost:3001 (admin/admin) |
| Prometheus | http://localhost:9090 |
| Alertmanager | http://localhost:9093 |
| Kafka UI | http://localhost:8090 |
| Databases | localhost:5432-5438 (Postgres) and localhost:27017 (catalogdb, MongoDB), same ports as compose |

Docker Desktop implements `type: LoadBalancer` by binding the port on the host,
so these are real host ports rather than port-forwards. Each is a separate
`<name>-lb` Service; the in-cluster Service keeps the original name and port
(`frontend:80`, `grafana:3000`) so nothing in the monitoring configs had to
change.

## What the move to Kubernetes changed, and why

Most of the stack is a mechanical translation. These are the parts that are
not, and would break silently if reverted.

**Kafka binds `0.0.0.0`, not `kafka`.** Under compose the hostname `kafka`
resolves to the container's own IP, so `KAFKA_LISTENERS: PLAINTEXT://kafka:29092`
binds fine. Here `kafka` is a Service VIP that exists on no interface and the
broker cannot bind it. Listeners bind the wildcard; `KAFKA_ADVERTISED_LISTENERS`
still publishes `kafka:29092`. The controller quorum voter has to name the pod
itself (`kafka-0.kafka-headless...`) rather than the VIP, and the headless
Service sets `publishNotReadyAddresses` so that name resolves while the broker
is still starting.

**Kafka sets `enableServiceLinks: false`.** Kubernetes injects Docker-link-style
variables for every Service in the namespace, so the Service named `kafka` puts
`KAFKA_PORT=tcp://10.x.x.x:29092` into the broker's own pod. cp-kafka's
configure script reads `KAFKA_PORT` as the deprecated `port` broker setting,
writes it into `server.properties`, and exits 1 about a second after start —
after `Running in KRaft mode...` and before any Kafka log line, which reads like
a storage problem. The tell is the `port is deprecated` warning in the log.

**Eureka registers pod IPs.** The gateway routes with `lb://user-service`,
resolved through Eureka rather than kube-dns — Kubernetes Services are not in
that path at all. A pod's hostname is not resolvable by other pods, so
`EUREKA_INSTANCE_PREFER_IP_ADDRESS=true` in `02-config.yaml` is what keeps
gateway routing working. Pod IPs are routable cluster-wide.

**Liveness and readiness are separate endpoints.**
`MANAGEMENT_ENDPOINT_HEALTH_PROBES_ENABLED=true` splits `/actuator/health` into
`/actuator/health/liveness` and `/actuator/health/readiness`. Pointing liveness
at the aggregate endpoint instead would let a 30-second database blip fail the
probe and have Kubernetes kill every JVM at once.

**Init containers replace `depends_on`.** Kubernetes has no equivalent of
`condition: service_healthy`. Without the busybox waiters every service would
boot before postgres and Eureka, fail fast, and back off — CrashLoopBackOff
reaches 5 minutes between attempts, turning a 90-second cold start into ten.

**Requests are far below limits.** Limits match compose's `mem_limit` exactly
(and `-XX:MaxRAMPercentage=55` reads them from the same cgroup), but requests
are ~40% of that. Requests are what the scheduler adds up: at compose's numbers
the stack asks for ~14.6 GB against a 15.5 GB node and would not fit. Actual
steady-state usage is around 7 GB, so the overcommit is deliberate.

**The frontend's nginx config is overridden by ConfigMap.** The baked-in one
hardcodes Docker's embedded DNS at `127.0.0.11`, which does not exist in a pod.
It also routes `proxy_pass` through a variable to force re-resolution, a
workaround for container IPs changing on restart — a ClusterIP is stable for the
life of the Service, so that indirection is dropped.

**Promtail reads the Kubernetes API, not the Docker socket.** It discovers pods
instead of containers; RBAC for it is in `60-monitoring.yaml`. Three details
have to be right together or it silently ships nothing:

- a `__host__` relabel plus `HOSTNAME` from `spec.nodeName`. Promtail tails only
  pods on its own node and decides that by comparing the two. Without it every
  target is discarded — `promtail_targets_active_total 0`, and no error.
- a pipeline stage matching the runtime — `cri: {}` for containerd/CRI-O,
  `docker: {}` for cri-dockerd. Get it wrong and lines still ship, but nothing
  parses: no `level` label and no structured metadata. Check with
  `kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}'`.
- on cri-dockerd only, `/var/lib/docker/containers` mounted as well as
  `/var/log/pods`, because there the log files are symlinks into that tree.
  Without it the globs resolve and then every file fails with
  `stat failed ... no such file or directory`. Not needed on containerd, where
  the files are real.

**Gateway routing is unaffected by Kubernetes Services.** `lb://user-service`
resolves through Eureka, so `kubectl scale` works but the k8s Service is not in
the request path for `/api/**`.

**cAdvisor drops `--docker_only`.** That flag restricts it to Docker-managed
containers and would filter out the pods this stack is meant to measure.

This is the one place without full parity. On this cluster the standalone
cAdvisor DaemonSet only resolves cgroup *aggregates* — `container_memory_*{id="/kubepods"}`
— not per-pod series, so `06-containers.json` is largely empty. Node- and
cluster-level memory and CPU still work. The proper source for per-pod
container metrics under Kubernetes is the kubelet's own cAdvisor endpoint
(`/metrics/cadvisor`), which is fully labelled with pod, namespace and
container. Wiring it up means a scrape job with a bearer token and RBAC for
`nodes/metrics`, which would have to live in `prometheus.yml` — and that file is
deliberately shared byte-for-byte with the compose stack, where such a job is
meaningless. Adding it is a reasonable next step; it just costs that shared
config.

**Stateful components chown their volume first.** Prometheus (65534), Grafana
(472), Loki and Tempo (10001) run as non-root, and a freshly provisioned PVC is
owned by root. Without the root init container they start, fail to open their
data directory, and crash-loop.

## Monitoring config

`05-monitoring-config.yaml` is generated — do not edit it. Kustomize refuses to
read files outside its own root and `ecommerce-monitoring` is a sibling repo, so
the choice was to copy nine config files in (two sources of truth, certain to
drift) or render them on demand. Edit the originals under
`../../ecommerce-monitoring/`, then:

```bash
./sync-monitoring-config.sh   # or just re-run deploy.ps1 / deploy.sh
kubectl apply -k .
```

`prometheus.yml`, `alertmanager.yml`, `loki-config.yml` and `tempo-config.yml`
are mounted with `subPath`, and subPath mounts never see ConfigMap updates — so
after re-applying a changed config those pods need a restart
(`kubectl -n ecommerce rollout restart deployment/prometheus`); the
`--web.enable-lifecycle` reload endpoint cannot help because the file inside the
pod has not changed. Rules and dashboards are directory mounts and refresh on
their own within about a minute.

`prometheus.yml` needed no changes at all: it addresses everything by service
name and port, and those names are preserved here.

## Operating

```bash
kubectl -n ecommerce get pods
kubectl -n ecommerce logs -f deployment/order-service
kubectl -n ecommerce rollout restart deployment/user-service
kubectl -n ecommerce scale deployment/product-service --replicas=3   # Eureka handles the rest
kubectl -n ecommerce exec -it userdb-0 -- psql -U useruser userdb
kubectl -n ecommerce exec -it catalogdb-0 -- mongosh -u cataloguser -p catalogpass --authenticationDatabase admin catalogdb
```

After rebuilding an image, the tag does not change, so Kubernetes has no reason
to restart anything:

```bash
./build-images.sh
kubectl -n ecommerce rollout restart deployment/user-service
```

**catalogdb is MongoDB.** It keeps the StatefulSet name, Service name and PVC
template of its Postgres neighbours, so `deploy.sh` and the init containers did not
change — only the port (27017) and the image did. On a cluster that ran the
earlier Postgres `catalogdb`, the reused PVC `data-catalogdb-0` still holds the old
`pgdata/` directory; mongod lives in its own `mongo/` subPath and ignores it, but
it is dead weight, so drop it once:

```bash
kubectl -n ecommerce delete statefulset catalogdb
kubectl -n ecommerce delete pvc data-catalogdb-0
kubectl -n ecommerce delete deployment,service postgres-exporter-catalogdb   # apply does not prune it
./deploy.sh
```

Teardown keeps data unless told otherwise:

```bash
./teardown.sh              # workloads only; PVCs survive
./teardown.sh --with-data  # deletes the namespace and every database
```

## Notes

**Rollouts are hitless.** A `rollout restart` used to produce 30-second hangs
and 500s for up to a minute: the gateway (and Feign callers) kept dialling the
terminated pod's IP until Eureka stopped advertising it. Four things, all
needed together, make a rollout invisible to callers now (measured: 0 failed
requests, worst case ~0.4s, while catalog-service, the gateway itself and
order-service were restarted back to back under continuous load — the same
scenario failed 13 of ~430 requests before):

- **Eureka server** (`service-discovery`): `use-read-only-response-cache: false`.
  The read-only cache is refreshed only every 30s, so registrations,
  deregistrations and status changes stayed invisible to every fetching client
  for up to half a minute — the single biggest contributor.
- **Eureka clients** (every Spring service): registry fetch every 5s, lease
  renewal 5s / expiry 15s (defaults 30s / 30s / 90s), LoadBalancer cache 5s.
  A *crashed* instance is gone within ~20s; a graceful stop does not wait for it.
- **preStop drain** (`40-services.yaml`): before SIGTERM the pod POSTs
  `OUT_OF_SERVICE` to its own `/actuator/serviceregistry`, then sleeps 15s while
  still serving. Every peer has dropped it by then, so Boot's graceful shutdown
  (default in Boot 4) only has in-flight requests to finish.
  `terminationGracePeriodSeconds: 60` covers 15s drain + 30s graceful phase.
- **Retry on connection failure only**: the gateway (`Retry` default filter,
  `connect-timeout: 3000`) and the Feign clients (`FeignConfig.ConnectionFailureRetryer`,
  `connect-timeout: 2000`) retry a request whose TCP connect failed — it never
  reached an instance, so replaying any method is safe — and the LoadBalancer
  picks the next instance. Read timeouts and 5xx are deliberately *not* retried.

Two Eureka quirks to know when poking at this by hand: a client-reported UP
after OUT_OF_SERVICE takes up to ~25s to reach the server (status replication is
rate-limited; a fresh pod registers within seconds, which is what rollouts rely
on), and `kubectl delete pod --grace-period=0` skips preStop — that is what the
lease expiry and the connection-failure retry are for.

**Images are never pulled.** They are tagged `ecommerce/<name>:local` with
`imagePullPolicy: IfNotPresent`. Docker Desktop's kubeadm cluster shares the
local image store, so no registry is involved. The kind cluster does not: its
node has its own containerd cache, fetches a local-only image from Docker the
first time it is asked for and — because of `IfNotPresent` — never asks again
for a tag it already holds. A rebuild under the same `:local` tag therefore
ships the *old* jar until the node's copy is refreshed; `build-images.sh` /
`build-images.ps1` run `crictl pull` on the node for every image when they
detect the kind provisioner, so the documented flow stays correct on both.
On any other cluster these
manifests need real registry references — `docker-compose.registry.yml` already
names the Docker Hub images to point at.

**Single replica everywhere**, matching compose. The Spring services scale
horizontally as-is (Eureka load-balances, and the databases are per-service);
the databases, Kafka and the monitoring components do not — they are
single-instance by design here.

**Log rotation depends on the container runtime, and it is worth checking.**
A poison-pill message on `shipment.created` once had notification-service log a
deserialization stack trace in a tight retry loop and write **992 GB** in 17
hours. That filled the Docker VM disk, tainted the node with DiskPressure, and
made the cluster unschedulable — and because a WSL2 virtual disk never shrinks,
deleting the log did not give the space back to Windows; the disk had to be
recreated.

Under the **kind** provisioner (containerd) the node reports
`containerRuntimeVersion: containerd://2.x`, `/var/log/pods/<pod>/<container>/0.log`
is a real file, and kubelet rotates it at its default 10 MB × 5. Bounded.

Under **kubeadm** (cri-dockerd, `docker://29.x`) those log files are symlinks
into `/var/lib/docker/containers` and `docker inspect` on a pod container shows
`logdriver=json-file opts=map[]` — kubelet's cap is *not* in effect. If you run
that mode, bound it in `C:\Users\<you>\.docker\daemon.json`:

```json
"log-driver": "json-file",
"log-opts": { "max-size": "50m", "max-file": "3" }
```

Note that Docker Desktop rewrites `daemon.json` from its own settings store on
restart, so make that change through Settings → Docker Engine rather than by
editing the file. `docker-compose.yml` bounds the compose side independently
with its `x-default-logging` anchor (50 MB × 3).
