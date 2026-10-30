FROM koalaman/shellcheck-alpine:v0.10.0 AS shell-validation

WORKDIR /workspace
COPY *.sh ./
COPY k8s/check-promtail-parity.sh k8s/check-frontend-nginx-parity.sh k8s/sync-monitoring-config.sh ./k8s/
RUN sed -i 's/\r$//' build-all.sh rebuild.sh smoke-test.sh \
    && shellcheck --severity=warning build-all.sh rebuild.sh smoke-test.sh \
    && shellcheck --severity=warning k8s/check-promtail-parity.sh k8s/check-frontend-nginx-parity.sh k8s/sync-monitoring-config.sh

FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04 AS powershell-validation

WORKDIR /workspace
COPY *.ps1 ./
COPY .circleci/validate-powershell.ps1 /validate-powershell.ps1
RUN pwsh -NoLogo -NoProfile -NonInteractive -File /validate-powershell.ps1

# The Kubernetes manifests are the mirror of docker-compose.yml (ADR-012) and nothing
# else in CI reads them: a YAML mistake is otherwise found by `kubectl apply` on a
# developer's machine. This only proves they parse; the contents are covered by the
# parity scripts in k8s/ and the monitoring repository's own validation.
FROM python:3.13-alpine AS manifest-validation

RUN pip install --no-cache-dir PyYAML==6.0.2
WORKDIR /workspace
COPY k8s/*.yaml ./k8s/
RUN python -c "import glob, yaml; files = sorted(glob.glob('k8s/*.yaml')); [list(yaml.safe_load_all(open(f, encoding='utf-8'))) for f in files]; print('parsed', len(files), 'manifests')"
