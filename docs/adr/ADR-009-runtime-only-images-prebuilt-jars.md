# ADR-009: Runtime-only images built from prebuilt jars

- **Status:** Accepted
- **Recorded:** 2026-10-29, reconstructed from the Dockerfiles, the build scripts and the CI configuration.

## Context

Compiling inside a Docker build means downloading the Maven dependency tree
into every image build (or maintaining cache mounts), and it duplicates the
test run CI already does. The JVM services need a small, unprivileged runtime
image that stops cleanly.

## Decision

- Each Spring service's `docker/Dockerfile` is **runtime-only**: `FROM eclipse-temurin:25-jre-alpine`, `COPY ./target/<name>-*.jar app.jar`, a non-root `app` user, and `ENTRYPOINT ["sh","-c","exec java $JAVA_OPTS -jar app.jar"]`. `exec` makes the JVM PID 1, so it receives SIGTERM directly.
- Maven runs **on the host or in CI**, before the image build. `build-all.*` and `rebuild.*` orchestrate both steps locally. CI builds the jar in a `verify` job, rebuilds the image without credentials in `validate-image`, and publishes only from `develop`, `main`/`master` and `v*` tags.
- `.dockerignore` files are allow-lists: only the Dockerfile and the packaged jar enter the build context.
- JVM sizing comes from the environment: `-XX:MaxRAMPercentage=55 -XX:ActiveProcessorCount=2 -XX:+ExitOnOutOfMemoryError`, against a container memory limit of 640–768 MB.

## Consequences

Positive:
- Small, fast image builds, and one compilation per change.
- The same image runs under compose (local build), Kubernetes (`ecommerce/<name>:local`) and from Docker Hub (`docker-compose.registry.yml`).

Negative:
- **The stale-jar trap.** `docker compose build` succeeds against whatever jar is in `target/`, so skipping Maven ships old code with no error. It is the most common "my fix didn't apply" cause, which is why `k8s/build-images.*` refuses to run without jars and why every runbook entry mentions it.
- Images are not reproducible from the repository alone. They depend on a host build step.

## Related

[Onboarding](../onboarding.md) · [Runbook](../runbook.md) · [CICD.md](../../CICD.md)
