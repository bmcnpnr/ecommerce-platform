# CircleCI CI/CD

Each directory in this workspace is an independent Git repository and therefore
an independent CI project. Ten repositories own their pipeline in
`.circleci/config.yml`.

> **Three repositories have moved to GitHub Actions:** ecommerce-service-discovery,
> ecommerce-shipping-service and ecommerce-user-service. Their
> `.github/workflows/ci-cd.yml` is a port of the CircleCI pipeline below, with
> the same three jobs (verify → validate-image → publish-image), the same
> trusted-ref publishing rules and image tags. Docker Hub credentials come from
> the repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_ACCESS_TOKEN`
> instead of the `ecommerce-dockerhub` context. Their CircleCI configs were
> removed, so skip them in the CircleCI setup steps below.

## Pipeline coverage

| Repository type | CI | Continuous delivery |
|---|---|---|
| Ten Java 25 / Spring Boot services | Maven verify on a Docker-enabled VM, tests, JAR and Docker build | Docker Hub image |
| React / TypeScript frontend | Vitest, TypeScript/Vite and Docker build. Playwright e2e on demand (pipeline parameters `run-e2e`, `e2e-base-url`), against an environment that is already running | nginx Docker Hub image |
| Monitoring configuration | YAML/JSON, Prometheus, Alertmanager validation | Versioned config bundle |
| Platform orchestration | Compose, ShellCheck, PowerShell parser | Versioned deployment bundle |

CI runs for every branch, pull request branch, and Git tag. Docker publishing
is restricted to trusted delivery refs:

| Git ref | Docker tags |
|---|---|
| Feature/PR branch or non-release tag | No publish; CI only |
| `develop` | `develop`, `sha-<12-character-commit>` |
| `main` or `master` | `latest`, `sha-<12-character-commit>` |
| `v*` tag | Exact Git tag, `sha-<12-character-commit>` |

## One-time CircleCI setup

1. In CircleCI Organization Settings, create a context named
   `ecommerce-dockerhub`.
2. Add `DOCKERHUB_USERNAME` and `DOCKERHUB_ACCESS_TOKEN` to that context.
   Use a Docker Hub access token, not an account password.
3. If the context uses project restrictions, authorize all eleven image
   repositories.
4. Connect all thirteen GitHub repositories as CircleCI projects. Keep
   `.circleci/config.yml` as the config path and enable push and PR triggers.
5. Create these Docker Hub repositories if they do not already exist:

   - `ecommerce-service-discovery`
   - `ecommerce-api-gateway`
   - `ecommerce-user-service`
   - `ecommerce-product-service`
   - `ecommerce-catalog-service`
   - `ecommerce-order-service`
   - `ecommerce-payment-service`
   - `ecommerce-shipping-service`
   - `ecommerce-review-service`
   - `ecommerce-notification-service`
   - `ecommerce-frontend`

The Docker Hub context is attached only to publish jobs. Feature branches and
pull-request jobs never receive registry credentials.

### Unset pipeline values render as `<nil>`

CircleCI substitutes an unset pipeline value with the literal four-character
string `<nil>`, not with an empty string. A branch build therefore reaches the
publish job with `GIT_TAG=<nil>`, which passes a `[[ -n ... ]]` test and yields
an unusable image reference:

```
Error parsing reference: "<user>/ecommerce-catalog-service:<nil>"
is not a valid repository/tag: invalid reference format
```

Every publish job normalises `GIT_TAG` and `GIT_BRANCH` to empty before reading
them. Keep that normalisation when editing these jobs, and use explicit `if`
blocks rather than `[[ ... ]] && VAR=""` — under `set -e` a false one-liner is
the last command in the list and aborts the step.

## Docker validation and build contexts

Every deployable repository builds its runtime image on every branch and tag
after application verification. This credential-free job catches invalid
Dockerfiles, missing build outputs, and incompatible base-image changes before
merge. Trusted delivery refs intentionally build once more in the isolated
publish job; registry credentials are never exposed to untrusted refs.

The Spring repositories use allow-list `.dockerignore` files: only the runtime
Dockerfile and packaged JAR enter the Docker build context. The frontend omits
dependencies, build/test output, editor files, CI configuration, logs, and
local environment files. Keep secrets out of both build arguments and image
layers; runtime secrets belong in the deployment environment.

## Testcontainers-ready Java verification

The Java `verify` jobs use the pinned CircleCI Linux machine image
`ubuntu-2404:2026.05.1`, then run Maven in `cimg/openjdk:25.0`. The checkout is
mounted at the same absolute path inside the build container, and the host
Docker socket is mounted with the job user's UID/GID. A dedicated writable
build home keeps Maven/Testcontainers state isolated and makes UID differences
between machine-image revisions harmless. This is the supported
"Docker wormhole" layout: future Testcontainers tests can start PostgreSQL,
Kafka, or other dependencies without changing the CircleCI executor.

When adding integration tests to a service:

1. Add a pinned Testcontainers BOM and only the test-scoped modules that the
   service owns, such as PostgreSQL or Kafka.
2. Let tests allocate random host ports and isolated networks. Do not depend on
   the full platform Compose stack or fixed container names.
3. Keep Testcontainers cleanup enabled and do not enable reusable containers in
   CI. Pin dependency image versions so upstream `latest` changes cannot break
   a build unexpectedly.
4. Run fast tests with Surefire. Name integration tests `*IT` and configure
   Maven Failsafe when a service needs a distinct integration-test phase.
5. Keep `mvn verify` as the CI entry point. Both `target/surefire-reports` and
   `target/failsafe-reports` are already collected by CircleCI.

No `TESTCONTAINERS_HOST_OVERRIDE` is required for this Linux VM arrangement.
The pipelines set only `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` for the mounted
socket used by Testcontainers' cleanup container.

## Contract tests in the pipeline

Every repository that talks to another runs Pact contract tests as part of the
ordinary `mvn verify` (they are plain Surefire tests — no broker, no Docker, the
Kafka ones use an embedded KRaft broker):

- Consumer tests (`*ConsumerPactTest`) generate `target/pacts/*.json` and fail if
  the service's own client code cannot drive the recorded interactions.
- Provider tests (`*ProviderPactTest`) replay the **committed** pacts in
  `src/test/resources/pacts/` against the real application and fail if the service
  no longer honours a consumer's expectations.

Because each repository is its own CircleCI project, pacts are distributed as
committed files rather than through a Pact broker: after changing a consumer's
expectations run `./sync-pacts.sh` from `ecommerce-platform`, then commit the
updated `src/test/resources/pacts/*.json` in the provider repositories alongside the
consumer change. Nothing in `.circleci/config.yml` needs to change for this.
Consumer tests bind Pact mock servers to fixed ports (18082/18083/18087 for
product-service's consumers, 18181/18187 for the gateway's); they are inside the
`verify` job's Docker container, so they cannot collide between pipelines.

## Deploy delivered images

The normal `docker-compose.yml` remains optimized for local source builds. The
registry overlay switches application services to pipeline-produced images.

Linux/macOS:

```bash
export DOCKERHUB_USERNAME=bmcnpnr
export IMAGE_TAG=develop
docker login
docker compose -f docker-compose.yml -f docker-compose.registry.yml pull
docker compose -f docker-compose.yml -f docker-compose.registry.yml up -d --no-build
```

PowerShell:

```powershell
$env:DOCKERHUB_USERNAME = 'bmcnpnr'
$env:IMAGE_TAG = 'develop'
docker login
docker compose -f docker-compose.yml -f docker-compose.registry.yml pull
docker compose -f docker-compose.yml -f docker-compose.registry.yml up -d --no-build
```

Use `IMAGE_TAG=latest` for main, or use a coordinated `v*` release after that
tag has been pushed to every deployable repository.

## Deployment boundary

These pipelines implement continuous delivery: tested images and validated
deployment bundles are produced automatically. They do not SSH into an
unspecified server or mutate a Kubernetes/cloud environment. Add a production
deployment job only after its target, credentials, health check, and rollback
method are defined.

CircleCI references:

- https://circleci.com/docs/guides/orchestrate/pipelines/
- https://circleci.com/docs/guides/security/contexts/
- https://circleci.com/docs/guides/execution-managed/building-docker-images/
- https://circleci.com/docs/guides/execution-managed/using-linuxvm/
- https://java.testcontainers.org/supported_docker_environment/continuous_integration/circle_ci/
- https://java.testcontainers.org/supported_docker_environment/continuous_integration/dind_patterns/
- https://docs.docker.com/build/concepts/context/
