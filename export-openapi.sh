#!/usr/bin/env bash
#
# Regenerate the committed OpenAPI documents in docs/api/openapi/ from a running
# stack. Each spec is fetched through the gateway's /api-docs/<service> route —
# the same one the unified Swagger UI at /swagger-ui.html uses — so this also
# proves those routes and the services' springdoc endpoints work.
#
#   ./export-openapi.sh                      # against localhost:8080
#   GW=http://host:8080 ./export-openapi.sh
#
# Needs Node.js, to pretty-print the documents and point "servers" at the
# gateway: the services declare a relative "/" server so Swagger UI's "Try it
# out" stays on the gateway, which means nothing to a file opened in Postman or
# an editor.
set -euo pipefail

GW="${GW:-http://localhost:8080}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)/docs/api/openapi"
SERVICES=(user-service product-service catalog-service order-service payment-service shipping-service review-service)

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }

# Node on Windows cannot open Git Bash's /c/... or /tmp/... paths.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

mkdir -p "$OUT_DIR"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

failed=0
for svc in "${SERVICES[@]}"; do
  if ! curl -sf --max-time 30 "$GW/api-docs/$svc" -o "$tmp"; then
    echo "  FAIL  $svc: no spec at $GW/api-docs/$svc (is the service registered in Eureka?)" >&2
    failed=$((failed + 1))
    continue
  fi
  SPEC_IN="$(native_path "$tmp")" SPEC_OUT="$(native_path "$OUT_DIR/$svc.json")" GATEWAY_URL="$GW" \
    node --input-type=module <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';
const spec = JSON.parse(readFileSync(process.env.SPEC_IN, 'utf8'));
spec.servers = [{ url: process.env.GATEWAY_URL, description: 'API gateway' }];
// springdoc lists some schema properties (Spring's Page types) in JVM reflection
// order, which differs between runs; sorting them keeps regenerated files diff-clean.
const sortProperties = (node) => {
  if (Array.isArray(node)) return node.forEach(sortProperties);
  if (!node || typeof node !== 'object') return;
  for (const [key, value] of Object.entries(node)) {
    if (key === 'properties' && value && typeof value === 'object' && !Array.isArray(value)) {
      node[key] = Object.fromEntries(Object.keys(value).sort().map((k) => [k, value[k]]));
    }
    sortProperties(node[key]);
  }
};
sortProperties(spec);
writeFileSync(process.env.SPEC_OUT, JSON.stringify(spec, null, 2) + '\n');
const ops = Object.values(spec.paths ?? {}).reduce((n, p) => n + Object.keys(p).length, 0);
console.log(`  OK    ${basename(process.env.SPEC_OUT)}: ${ops} operations`);
JS
done

[ "$failed" -eq 0 ] || exit 1
