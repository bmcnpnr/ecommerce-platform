#!/usr/bin/env bash
# Creates ecommerce-platform/.env with freshly generated secrets for the local
# stack. docker compose reads .env from this directory automatically, and
# k8s/deploy.sh turns it into the platform-secrets and eureka-credentials
# Secrets. .env is git-ignored: secrets never go into the repository (S-4).
#
#   ./init-secrets.sh            # create .env, or add any keys it is missing
#   ./init-secrets.sh --print    # also print the admin and Grafana logins
#
# Existing values are never changed, so re-running is safe. To rotate a secret,
# delete its line (or the whole file) and run this again, then redeploy.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"

# Alphanumeric only: the values end up in URLs (Eureka) and shell commands.
random_alnum() { # length
  local out=""
  while [[ ${#out} -lt $1 ]]; do
    out+="$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  echo "${out:0:$1}"
}

touch "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true

add() { # key value
  if ! grep -q "^$1=" "$ENV_FILE"; then
    echo "$1=$2" >> "$ENV_FILE"
    echo "  generated $1"
  fi
}

echo "Secrets in $ENV_FILE:"
# HS512 needs at least 64 bytes; the gateway and user-service refuse anything shorter.
add JWT_SECRET "$(random_alnum 86)"
add ADMIN_USERNAME admin
add ADMIN_PASSWORD "$(random_alnum 24)"
add EUREKA_USERNAME eureka
add EUREKA_PASSWORD "$(random_alnum 32)"
add GRAFANA_ADMIN_USER admin
add GRAFANA_ADMIN_PASSWORD "$(random_alnum 24)"
echo "  done (existing values kept)"

if [[ "${1:-}" == "--print" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo
  echo "Shop admin : $ADMIN_USERNAME / $ADMIN_PASSWORD"
  echo "Grafana    : $GRAFANA_ADMIN_USER / $GRAFANA_ADMIN_PASSWORD"
  echo "Eureka     : $EUREKA_USERNAME / $EUREKA_PASSWORD"
fi
