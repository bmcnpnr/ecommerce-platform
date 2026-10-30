# Payment service API reference

Call the API through the gateway at `http://localhost:8080`. The service also listens directly on `http://localhost:8085`, which bypasses the gateway and its JWT check; use that for development only.

- **Try it:** the platform Swagger UI at `http://localhost:8080/swagger-ui.html`, entry `payment-service`. Calls go through the gateway, so click **Authorize** with a token from `POST /api/v1/users/login` first.
- **OpenAPI document:** `http://localhost:8080/api-docs/payment-service` (through the gateway), `http://localhost:8085/api-docs` (direct), or the committed snapshot [openapi/payment-service.json](openapi/payment-service.json).

Service overview: [payment-service](../services/payment-service.md).

## Conventions

- **Content type:** request and response bodies are `application/json`. A body sent with any other `Content-Type` is 415.
- **Authentication:** every path needs `Authorization: Bearer <JWT>` at the gateway. Without a valid token the gateway answers 401 with an empty body, and the request never reaches the service. The service also checks identity (`security/PaymentAccess`): no `X-Username` is 401 `Authentication required`; a payment, order or customer that is not the caller's is 403 `Access denied`; `ADMIN` (exact) may read and process any payment and is the only role that may refund. Responses carry `nosniff` and `no-store`.
- **Correlation:** every response carries `X-Correlation-Id`. The service reuses the incoming value if it matches `^[A-Za-z0-9._-]{1,64}$`, otherwise generates a UUID.
- **Dates:** REST uses Spring Boot 4's Jackson 3 defaults (no `spring.jackson.*` settings and no custom mapper). `LocalDateTime` is written as an ISO-8601 local date-time string without zone, for example `2026-10-29T14:30:15.123456`. Values have no time zone; they are the JVM's local time, and neither the compose nor the k8s manifests set `TZ`.
- **Numbers:**
  - `amount` is a JSON number. A value read back from the database has the column's 4 decimals (`99.9800`). The create response echoes the request's own scale.
  - Ids are JSON integers.
- **Enums** are sent as their names:
  - `status`: `PENDING`, `PROCESSING`, `COMPLETED`, `FAILED`, `REFUNDED`.
  - `method`: `CREDIT_CARD`, `DEBIT_CARD`, `BANK_TRANSFER`, `DIGITAL_WALLET`.
- **Pagination:** only the customer's payment list is paged: optional `page` (from 0, default 0) and `size` (1 to 100, default 100), newest first (by id, descending). It still returns a plain JSON array, so a client that sends no parameter gets the newest 100 payments. A `page` below 0 or a `size` outside 1 to 100 is 400, not clamped.

### Error body

`exception/GlobalExceptionHandler.java` writes every error as an `ErrorResponse`:

```json
{
  "timestamp": "2026-10-29T14:31:02.481516",
  "status": 404,
  "error": "Not Found",
  "message": "Payment not found: 99",
  "path": "/api/v1/payments/99",
  "correlationId": "5b0c7a2e-3f1d-4c8e-9a4b-1f2e3d4c5b6a",
  "fieldErrors": null
}
```

A validation failure sets `message` to `Validation failed` and fills `fieldErrors`. The order of the entries is not defined.

```json
{
  "timestamp": "2026-10-29T14:31:02.481516",
  "status": 400,
  "error": "Bad Request",
  "message": "Validation failed",
  "path": "/api/v1/payments",
  "correlationId": "5b0c7a2e-3f1d-4c8e-9a4b-1f2e3d4c5b6a",
  "fieldErrors": [
    { "field": "amount", "message": "must be greater than or equal to 0.01" },
    { "field": "method", "message": "must not be blank" }
  ]
}
```

### Exception to status mapping

| Exception | Status | `error` | `message` |
|---|---|---|---|
| `PaymentNotFoundException` | 404 | `Not Found` | `Payment not found: {id}` or `Payment not found for order: {orderId}` |
| `PaymentAlreadyProcessedException` | 409 | `Conflict` | `Payment already completed for order: {orderId}`, `Payment already in status: {status}`, `A payment already exists for order: {orderId}` (another customer), `The payment for this order was declined and the order is cancelled. Place a new order to try again.` (the order's payment is `FAILED`), `Payment for order {orderId} is in status {status} and cannot be initiated again`, or a concurrent-create / concurrent-process message |
| `InvalidPaymentStateException` | 400 | `Bad Request` | `Can only refund COMPLETED payments. Current: {status}` or `Amount does not match the order total` |
| `BadRequestException` (`page`, `size`) | 400 | `Bad Request` | `page must be at least 0 and size between 1 and 100` |
| `InvalidPaymentMethodException` | 400 | `Bad Request` | `Unsupported payment method` |
| missing identity | 401 | `Unauthorized` | `Authentication required` |
| `ForbiddenException` | 403 | `Forbidden` | `Access denied` |
| `OrderNotFoundException` (order-service has no such order) | 404 | `Not Found` | `Order not found: {orderId}` |
| `OrderNotPayableException` | 409 | `Conflict` | `Order {orderId} is not awaiting payment` |
| `ObjectOptimisticLockingFailureException` | 409 | `Conflict` | `The payment was modified by another request` |
| `DependencyUnavailableException` (order-service gave no usable answer: connect failure, timeout, no instance, 5xx, an undecodable body, or an open circuit breaker) | 503 | `Service Unavailable` | `Order service unavailable. Please try again later.` |
| A dependency of this service does not answer: the database (connection wait over 5 s, lock timeout, a connection lost during commit or rollback), a Kafka timeout | 503 | `Service Unavailable` | `Service temporarily unavailable` |
| `MethodArgumentNotValidException` (`@Valid` body) | 400 | `Bad Request` | `Validation failed`, with `fieldErrors` |
| `HttpMessageNotReadableException` (missing or malformed body) | 400 | `Bad Request` | `Malformed request body` |
| `MethodArgumentTypeMismatchException` (for example a non-numeric `{id}`) | 400 | `Bad Request` | `Invalid value for parameter '{name}'` |
| other binding errors | 400 | `Bad Request` | `Invalid request` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | `Request method not supported` |
| not acceptable / unmapped path | 406 / 404 | | `Requested media type not acceptable` / `Resource not found` |
| Anything else | 500 | `Internal Server Error` | `An unexpected error occurred`, logged at ERROR with the stack trace, once per failure site per 10 s |

A 503 of either kind writes one WARN per exception class per 10 s, without a stack trace.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/payments` | Bearer JWT | `customerId` is the caller (or `ADMIN`); order verified with order-service | Create a `PENDING` payment |
| GET | `/api/v1/payments/{id}` | Bearer JWT | owner or `ADMIN` | Get a payment by id |
| GET | `/api/v1/payments/order/{orderId}` | Bearer JWT | owner or `ADMIN` | Get the payment of an order |
| GET | `/api/v1/payments/customer/{customerId}` | Bearer JWT | that customer or `ADMIN`; `page` at least 0, `size` 1 to 100 | List a customer's payments, newest first |
| POST | `/api/v1/payments/{id}/process` | Bearer JWT | owner or `ADMIN` | Settle with the simulated gateway (80 % success) |
| POST | `/api/v1/payments/{id}/refund` | `ADMIN` | `ADMIN` | Refund a `COMPLETED` payment in full |

The examples below assume `GW=http://localhost:8080` and `AUTH="Authorization: Bearer $TOKEN"`; admin-only calls use `ADMIN_AUTH` (a token for `admin` with `ADMIN_PASSWORD` from `ecommerce-platform/.env`). The api-test skill (`.claude/skills/api-test/SKILL.md`) shows how to get a token.

## POST /api/v1/payments

Creates a payment in `PENDING` for an order. Before storing anything the service asks order-service (`GET /internal/v1/orders/{orderId}`, `OrderVerifier`): the order must exist (404), be `CONFIRMED` (409), belong to the payer (403) and its total must equal `amount` exactly (400). If order-service cannot answer (no connection, a timeout, no instance, a server error, or its circuit breaker is open), the result is 503: a payment is never accepted blind. The frontend checkout sends the order's `totalAmount` and the username as `customerId`. Creating a payment does not settle it; call [process](#post-apiv1paymentsidprocess) next.

**Auth:** Bearer JWT. `customerId` must equal `X-Username` unless the caller is `ADMIN` (403 otherwise). A repeat for an order with an existing payment is allowed only for the same customer and only while it is `PENDING`, which is reused. A declined payment (`FAILED`) is final for its order.

**Request body** `InitiatePaymentRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `orderId` | integer (`Long`) | yes | `@NotNull`, `@Positive` | Verified against order-service (see above) |
| `customerId` | string | yes | `@NotBlank`, `@Size(max = 255)`, no control characters | Must be the caller's `X-Username` |
| `amount` | number (`BigDecimal`) | yes | `@NotNull`, `@DecimalMin("0.01")` (inclusive), `@Digits(integer = 15, fraction = 2)` | Must equal the order total. More decimals are 400 |
| `currency` | string | no | `@Pattern("^[A-Z]{3}$")` | Defaults to `USD` |
| `method` | string | yes | `@NotBlank`, `@Size(max = 30)` | Must be the exact enum name: `CREDIT_CARD`, `DEBIT_CARD`, `BANK_TRANSFER` or `DIGITAL_WALLET`. Anything else gives 400 |
| `cardLastFour` | string | no | `@Pattern("^[0-9]{4}$")` | Exactly four digits |

The default validation messages are `must not be null`, `must not be blank`, `must be greater than or equal to 0.01`, `must be a three-letter upper-case currency code` and `must be exactly four digits`.

```json
{
  "orderId": 7,
  "customerId": "alice",
  "amount": 99.98,
  "currency": "USD",
  "method": "CREDIT_CARD",
  "cardLastFour": "4242"
}
```

**Responses**

- `201 Created` with a [`PaymentDTO`](#paymentdto). There is no `Location` header. `transactionId`, `failureReason` and `updatedAt` are `null`.

  ```json
  {
    "id": 12,
    "orderId": 7,
    "customerId": "alice",
    "amount": 99.98,
    "currency": "USD",
    "status": "PENDING",
    "method": "CREDIT_CARD",
    "transactionId": null,
    "failureReason": null,
    "cardLastFour": "4242",
    "createdAt": "2026-10-29T14:30:15.123456",
    "updatedAt": null
  }
  ```

- `400` when validation fails (`fieldErrors` lists the fields) or the body is missing or malformed.
- `400` also for `Amount does not match the order total` and an unknown `method`.
- `401` / `403` no identity, another customer's `customerId`, or an order owned by someone else.
- `404` `Order not found: {orderId}`.
- `409`, in the order the service checks:
  - `Order {orderId} is not awaiting payment` when order-service says the order is not `CONFIRMED`. This comes first, so once order-service has cancelled the order after a decline, every retry gets this message;
  - `Payment already completed for order: {orderId}` when the order's payment is `COMPLETED`;
  - `A payment already exists for order: {orderId}` when the existing payment belongs to another customer (checked before the status below, so only the owner learns what became of it);
  - `The payment for this order was declined and the order is cancelled. Place a new order to try again.` when the existing payment is `FAILED`. This is the answer in the short window before order-service has consumed `payment.failed` and the order still reads `CONFIRMED`. Nothing is charged and nothing is published; the row stays `FAILED`;
  - `Payment for order {orderId} is in status {status} and cannot be initiated again` when the existing payment is `REFUNDED` or `PROCESSING`;
  - `A payment is already being created for order: {orderId}` when a concurrent request created or reset the row first.

  A `PENDING` payment of the same customer is reused.
- `503` with `Order service unavailable. Please try again later.` when order-service could not be asked. `503` with `Service temporarily unavailable` when the database does not answer.

**Side effects:** inserts one `payments` row (or resets a `PENDING` one). One Feign call to order-service. No event is published.

**Example**

```bash
curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"orderId":7,"customerId":"alice","amount":99.98,"currency":"USD","method":"CREDIT_CARD","cardLastFour":"4242"}' \
  "$GW/api/v1/payments"
```

## GET /api/v1/payments/{id}

Returns one payment.

**Auth:** Bearer JWT; the payment's `customerId` must equal `X-Username`, or the caller is `ADMIN` (403 otherwise).

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric; anything else gives 400 |

**Responses**

- `200 OK` with a [`PaymentDTO`](#paymentdto).
- `404` with `Payment not found: {id}`.
- `400` when `id` is not numeric.
- `401` / `403` no identity / not the owner.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/12"
```

## GET /api/v1/payments/order/{orderId}

Returns the payment of an order. The frontend's `OrderDetailPage` uses this endpoint.

**Auth:** Bearer JWT; owner of the order's payment, or `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `orderId` | path | integer (`Long`) | yes | Numeric |

**Responses**

- `200 OK` with a [`PaymentDTO`](#paymentdto).
- `404` with `Payment not found for order: {orderId}`.
- `403` the payment belongs to someone else. An order has one payment row (`order_id` is unique), and a declined payment stays `FAILED`: a new attempt for that order is refused (409), so this endpoint keeps returning the declined payment.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/order/7"
```

## GET /api/v1/payments/customer/{customerId}

Lists the payments whose `customerId` equals the path value exactly, newest first, one page at a time. The frontend's `useCustomerPayments()` hook would pass the username, but no page uses it.

**Auth:** Bearer JWT; `{customerId}` must equal `X-Username`, or the caller is `ADMIN` (403 otherwise). The check comes before the `page` and `size` validation.

**Path and query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `customerId` | path | string | yes | | Exact match |
| `page` | query | integer (`int`) | no | `0` | At least 0, else 400 |
| `size` | query | integer (`int`) | no | `100` | 1 to 100, else 400 (a larger value is rejected, not clamped) |

**Responses**

- `200 OK` with a JSON array of [`PaymentDTO`](#paymentdto), at most `size` long and ordered by `id` descending (newest first). The array is empty when nothing matches or the page is past the end; this endpoint never returns 404. It is still a plain array: ask for `page=1`, `page=2` and so on to read further back.
- `400` with `page must be at least 0 and size between 1 and 100`, or `Invalid value for parameter '{name}'` when `page` or `size` is not a number.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/customer/alice?page=0&size=20"
```

## POST /api/v1/payments/{id}/process

Settles a `PENDING` payment with the simulated gateway: `ThreadLocalRandom.current().nextInt(10) < 8` gives exactly 80 % success. **A declined payment still returns 200**, so the caller must read `status`.

| Outcome | `status` | `transactionId` | `failureReason` | Event |
|---|---|---|---|---|
| Success (draw 0 to 7) | `COMPLETED` | `TXN-` followed by 16 upper-case hex digits | `null` | `payment.completed` |
| Decline (draw 8 or 9) | `FAILED` | `null` | `Payment declined by gateway` | `payment.failed` |

**Auth:** Bearer JWT; owner of the payment, or `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric |

**Request body:** none.

**Responses**

- `200 OK` with a [`PaymentDTO`](#paymentdto) in its final status.

  ```json
  {
    "id": 12,
    "orderId": 7,
    "customerId": "alice",
    "amount": 99.9800,
    "currency": "USD",
    "status": "COMPLETED",
    "method": "CREDIT_CARD",
    "transactionId": "TXN-1A2B3C4D5E6F7A8B",
    "failureReason": null,
    "cardLastFour": "4242",
    "createdAt": "2026-10-29T14:30:15.123456",
    "updatedAt": "2026-10-29T14:30:16.002931"
  }
  ```

- `404` with `Payment not found: {id}`.
- `409` with `Payment already in status: {status}` when the payment is not `PENDING`, or `Payment is being processed by another request` when a concurrent call claimed it first.
- `503` with `Service temporarily unavailable` when the database does not answer. A Kafka outage does not reach this endpoint: the event waits in the outbox.

**Side effects:**

- Updates the `payments` row. The intermediate `PROCESSING` status is flushed inside the transaction and never committed.
- Inserts an `outbox_event` row for `payment.completed` or `payment.failed` (key `orderId`) in the same transaction. The relay publishes it to Kafka about half a second after the commit, at least once. If the transaction rolls back, nothing is published.
- Downstream:
  - order-service sets the order to `PAID`; on `payment.failed` it cancels the order, returns its stock and publishes no `order.cancelled`. After a decline, a new payment for the order is refused (409, see [POST /api/v1/payments](#post-apiv1payments)).
  - shipping-service creates a shipment on `payment.completed`.
  - notification-service logs a notification.

The payment row carries a `version` column (optimistic locking, migration `V3`), so two concurrent calls settle it once and write one event; the loser gets 409.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/payments/12/process"
```

## POST /api/v1/payments/{id}/refund

Refunds a `COMPLETED` payment in full. The endpoint takes no amount, so partial refunds are not possible. The status becomes `REFUNDED`, which is terminal, and `transactionId` is kept.

No service and no frontend page calls this endpoint. The `useRefundPayment()` hook exists in the frontend but is unused.

**Auth:** `ADMIN` only (403 at the gateway and in the service).

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric |

**Request body:** none.

**Responses**

- `200 OK` with a [`PaymentDTO`](#paymentdto) whose `status` is `REFUNDED`.
- `400` with `Can only refund COMPLETED payments. Current: {status}`.
- `404` with `Payment not found: {id}`.

**Side effects:**

- Updates the `payments` row.
- Inserts an `outbox_event` row for `payment.refunded` (full `amount`, key `orderId`) in the same transaction; the relay publishes it after the commit.
- Only notification-service consumes that topic. The order status and the shipment do not change.

**Example**

```bash
# admin token required
curl -s -X POST -H "$ADMIN_AUTH" "$GW/api/v1/payments/12/refund"
```

## Schemas

### `PaymentDTO`

Returned by every endpoint. Source: `dto/PaymentDTO.java`.

| Field | Type | Notes |
|---|---|---|
| `id` | integer (`Long`) | |
| `orderId` | integer (`Long`) | |
| `customerId` | string | As supplied when the payment was created |
| `amount` | number (`BigDecimal`) | 4 decimals once read back from the database |
| `currency` | string | |
| `status` | string | `PENDING`, `COMPLETED`, `FAILED` or `REFUNDED`. `PROCESSING` exists in the enum but is never returned |
| `method` | string | `PaymentMethod` name |
| `transactionId` | string or null | Set only when `COMPLETED` (kept after a refund) |
| `failureReason` | string or null | `Payment declined by gateway` when `FAILED` |
| `cardLastFour` | string or null | |
| `createdAt` | string (ISO-8601 local date-time) | |
| `updatedAt` | string or null | `null` until the payment is first processed or refunded |

### `InitiatePaymentRequest`

See [POST /api/v1/payments](#post-apiv1payments). Source: `dto/InitiatePaymentRequest.java`.

### `ErrorResponse`

Source: `exception/ErrorResponse.java`.

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string (ISO-8601 local date-time) | |
| `status` | integer | HTTP status |
| `error` | string | Reason phrase |
| `message` | string | See the mapping table |
| `path` | string | Request URI |
| `correlationId` | string | Same value as the `X-Correlation-Id` response header |
| `fieldErrors` | array of `{ "field": string, "message": string }`, or null | Set only on validation failures |
