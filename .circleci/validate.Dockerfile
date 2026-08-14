FROM koalaman/shellcheck-alpine:v0.10.0 AS shell-validation

WORKDIR /workspace
COPY *.sh ./
RUN sed -i 's/\r$//' build-all.sh rebuild.sh smoke-test.sh \
    && shellcheck --severity=warning build-all.sh rebuild.sh smoke-test.sh

FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04 AS powershell-validation

WORKDIR /workspace
COPY *.ps1 ./
COPY .circleci/validate-powershell.ps1 /validate-powershell.ps1
RUN pwsh -NoLogo -NoProfile -NonInteractive -File /validate-powershell.ps1
