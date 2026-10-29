#!/usr/bin/env bash
#
# End-to-end smoke test against a running stack, driven entirely through the
# API gateway on :8080 — so it exercises routing, Eureka discovery, JWT auth,
# the Feign hop to product-service, and the Kafka publish on order confirmation.
#
# Run from Git Bash / WSL, not PowerShell: PowerShell 5.1 strips the embedded
# double quotes when passing a JSON body to curl.exe, which arrives as a parse
# error and looks like an application bug.
#
#   ./smoke-test.sh              # against localhost:8080
#   GW=http://host:8080 ./smoke-test.sh
#
set -uo pipefail

GW="${GW:-http://localhost:8080}"
STAMP="$(date +%s)"
USERNAME="smoke$STAMP"
SKU="SKU-$STAMP"
PASSWORD='Passw0rd!123'

pass=0; fail=0

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@"; }
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "$3"; pass=$((pass+1))
  else
    printf '  \033[31mFAIL\033[0m  %-52s expected %s, got %s\n' "$1" "$2" "$3"; fail=$((fail+1))
  fi
}
note() { printf '\n\033[1m%s\033[0m\n' "$1"; }

note "Waiting for the gateway to route"
deadline=$((SECONDS + 180))
until [ "$(code "$GW/api/v1/products")" = "200" ]; do
  if [ $SECONDS -ge $deadline ]; then
    echo "  gateway did not become ready within 180s — is the stack up?"; exit 1
  fi
  sleep 5
done
echo "  ready"

note "Authentication and error semantics"
chk "register" 201 "$(code -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"email\":\"$USERNAME@example.com\",\"password\":\"$PASSWORD\",\"firstName\":\"Smoke\",\"lastName\":\"Test\"}" \
  "$GW/api/v1/users/register")"
chk "duplicate username rejected" 409 "$(code -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"email\":\"$USERNAME@example.com\",\"password\":\"$PASSWORD\"}" \
  "$GW/api/v1/users/register")"
chk "invalid field values rejected" 400 "$(code -X POST -H 'Content-Type: application/json' \
  -d '{"username":"x","email":"not-an-email","password":"1"}' "$GW/api/v1/users/register")"
chk "malformed JSON rejected" 400 "$(code -X POST -H 'Content-Type: application/json' \
  -d '{username:missing-quotes}' "$GW/api/v1/users/register")"

TOKEN=$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" "$GW/api/v1/users/login" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
if [ -n "$TOKEN" ]; then
  printf '  \033[32mPASS\033[0m  %-52s %s chars\n' "login returns a JWT" "${#TOKEN}"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "login returned no token"; fail=$((fail+1))
fi
AUTH="Authorization: Bearer $TOKEN"

note "Gateway authentication enforcement"
chk "authenticated request accepted" 200 "$(code -H "$AUTH" "$GW/api/v1/users/me")"
chk "missing token rejected"         401 "$(code "$GW/api/v1/users/me")"
chk "forged token rejected"          401 "$(code -H 'Authorization: Bearer not-a-real-token' "$GW/api/v1/users/me")"
chk "wrong verb on a route"          405 "$(code -X GET -H "$AUTH" "$GW/api/v1/orders")"

note "Public reads routed through Eureka (lb://)"
for path in products categories catalog; do
  chk "GET /api/v1/$path" 200 "$(code "$GW/api/v1/$path")"
done

note "Order flow: Feign to product-service, Kafka on confirm"
PRODUCT_ID=$(curl -s --max-time 30 -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"sku\":\"$SKU\",\"name\":\"Smoke Test Widget\",\"description\":\"created by smoke-test.sh\",\"price\":19.99,\"stockQuantity\":100,\"brand\":\"ACME\"}" \
  "$GW/api/v1/products" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)
if [ -n "$PRODUCT_ID" ]; then
  printf '  \033[32mPASS\033[0m  %-52s id=%s\n' "create product" "$PRODUCT_ID"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "create product"; fail=$((fail+1))
fi

ORDER_ID=$(curl -s --max-time 30 -X POST -H "$AUTH" "$GW/api/v1/orders?customerId=1" \
  | sed -n 's/.*"orderId":\([0-9]*\).*/\1/p')
if [ -n "$ORDER_ID" ]; then
  printf '  \033[32mPASS\033[0m  %-52s id=%s\n' "create order" "$ORDER_ID"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "create order"; fail=$((fail+1))
fi

# The add-item call makes order-service PATCH product-service over Feign.
chk "add item to order" 200 "$(code -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"productId\":$PRODUCT_ID,\"quantity\":2}" "$GW/api/v1/orders/$ORDER_ID/items")"
chk "unknown product surfaces as client error" 404 "$(code -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"productId":999999,"quantity":1}' "$GW/api/v1/orders/$ORDER_ID/items")"
chk "confirm order (publishes order.placed)" 200 "$(code -X POST -H "$AUTH" "$GW/api/v1/orders/$ORDER_ID/confirm")"
chk "list orders by customer" 200 "$(code -H "$AUTH" "$GW/api/v1/orders/customer/1")"

# catalog-service is the MongoDB-backed read model: sync pulls the product over
# Feign and upserts a document keyed by the product id; the reads below go
# back through that document, so this covers the Mongo round trip end to end.
note "Catalog read model (MongoDB): sync from product-service, then read back"
chk "sync product into catalog"        200 "$(code -X POST -H "$AUTH" "$GW/api/v1/catalog/sync/$PRODUCT_ID")"
chk "catalog entry by product id"      200 "$(code "$GW/api/v1/catalog/product/$PRODUCT_ID")"
if curl -s --max-time 30 "$GW/api/v1/catalog/product/$PRODUCT_ID" | grep -q "\"productSku\":\"$SKU\""; then
  printf '  \033[32mPASS\033[0m  %-52s sku=%s\n' "catalog entry carries the synced product" "$SKU"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "catalog entry does not carry sku $SKU"; fail=$((fail+1))
fi
chk "catalog search by name"           200 "$(code "$GW/api/v1/catalog/search?q=Smoke")"
chk "unknown product is 404 in catalog" 404 "$(code "$GW/api/v1/catalog/product/999999")"

# The stack runs under Docker Compose or Kubernetes (k8s/); read the consumer's
# log from whichever one is up.
notification_logs() {
  if [ -n "$(docker compose ps -q notification-service 2>/dev/null)" ]; then
    docker compose logs notification-service --since 2m 2>/dev/null
  else
    kubectl -n ecommerce logs deployment/notification-service --since=2m 2>/dev/null
  fi
}

note "Kafka consumer picked the event up"
sleep 5
# The trailing comma keeps orderId=6 from matching orderId=60.
if notification_logs | grep -q "orderId=$ORDER_ID,"; then
  printf '  \033[32mPASS\033[0m  %s\n' "notification-service consumed order $ORDER_ID"; pass=$((pass+1))
else
  printf '  \033[31mFAIL\033[0m  %s\n' "no notification logged for order $ORDER_ID"; fail=$((fail+1))
fi

printf '\n\033[1mRESULT: %d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
