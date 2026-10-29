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
- **Pagination:** none. The list endpoint returns a plain JSON array.

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
| `PaymentAlreadyProcessedException` | 409 | `Conflict` | `Payment already completed for order: {orderId}`, `Payment already in status: {status}`, `A payment already exists for order: {orderId}` (another customer), `Payment for order {orderId} is in status {status} and cannot be initiated again`, or a concurrent-create / concurrent-process message |
| `InvalidPaymentStateException` | 400 | `Bad Request` | `Can only refund COMPLETED payments. Current: {status}` or `Amount does not match the order total` |
| `InvalidPaymentMethodException` | 400 | `Bad Request` | `Unsupported payment method: {method}` |
| missing identity | 401 | `Unauthorized` | `Authentication required` |
| `ForbiddenException` | 403 | `Forbidden` | `Access denied` |
| `OrderNotFoundException` (order-service has no such order) | 404 | `Not Found` | `Order not found: {orderId}` |
| `OrderNotPayableException` | 409 | `Conflict` | `Order {orderId} is not awaiting payment` |
| `ObjectOptimisticLockingFailureException` | 409 | `Conflict` | `The payment was modified by another request` |
| `DependencyUnavailableException` (order-service unreachable) | 503 | `Service Unavailable` | `Order service unavailable. Please try again later.` |
| `MethodArgumentNotValidException` (`@Valid` body) | 400 | `Bad Request` | `Validation failed`, with `fieldErrors` |
| `HttpMessageNotReadableException` (missing or malformed body) | 400 | `Bad Request` | `Malformed request body` |
| `MethodArgumentTypeMismatchException` (for example a non-numeric `{id}`) | 400 | `Bad Request` | `Invalid value for parameter '{name}'` |
| other binding errors | 400 | `Bad Request` | `Invalid request` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | `Request method not supported` |
| not acceptable / unmapped path | 406 / 404 | | `Requested media type not acceptable` / `Resource not found` |
| Anything else, including database errors | 500 | `Internal Server Error` | `An unexpected error occurred`, logged at ERROR with the stack trace |

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/payments` | Bearer JWT | `customerId` is the caller (or `ADMIN`); order verified with order-service | Create a `PENDING` payment |
| GET | `/api/v1/payments/{id}` | Bearer JWT | owner or `ADMIN` | Get a payment by id |
| GET | `/api/v1/payments/order/{orderId}` | Bearer JWT | owner or `ADMIN` | Get the payment of an order |
| GET | `/api/v1/payments/customer/{customerId}` | Bearer JWT | that customer or `ADMIN` | List a customer's payments |
| POST | `/api/v1/payments/{id}/process` | Bearer JWT | owner or `ADMIN` | Settle with the simulated gateway (80 % success) |
| POST | `/api/v1/payments/{id}/refund` | `ADMIN` | `ADMIN` | Refund a `COMPLETED` payment in full |

The examples below assume `GW=http://localhost:8080` and `AUTH="Authorization: Bearer $TOKEN"`; admin-only calls use `ADMIN_AUTH` (a token for `admin` with `ADMIN_PASSWORD` from `ecommerce-platform/.env`). The api-test skill (`.claude/skills/api-test/SKILL.md`) shows how to get a token.

## POST /api/v1/payments

Creates a payment in `PENDING` for an order. Before storing anything the service asks order-service (`GET /internal/v1/orders/{orderId}`, `OrderVerifier`): the order must exist (404), be `CONFIRMED` (409), belong to the payer (403) and its total must equal `amount` exactly (400). If order-service cannot answer, the result is 503: a payment is never accepted blind. The frontend checkout sends the order's `totalAmount` and the username as `customerId`. Creating a payment does not settle it; call [process](#post-apiv1paymentsidprocess) next.

**Auth:** Bearer JWT. `customerId` must equal `X-Username` unless the caller is `ADMIN` (403 otherwise). A repeat for an order with an existing payment is allowed only for the same customer and only while it is `PENDING` or `FAILED`.

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
- `409` with `Payment already completed for order: {orderId}` when the order's payment is `COMPLETED`; `Order {orderId} is not awaiting payment` when the order is not `CONFIRMED`; and when the existing payment is `REFUNDED` or `PROCESSING`, or belongs to another customer. A `PENDING` or `FAILED` payment of the same customer is reused.
- `503` order-service could not be reached.

**Side effects:** inserts one `payments` row (or resets a `PENDING`/`FAILED` one). One Feign call to order-service. No event is published.

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
- `403` the payment belongs to someone else. An order has one payment row (`order_id` is unique): a retry after a decline reuses it.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/order/7"
```

## GET /api/v1/payments/customer/{customerId}

Lists every payment whose `customerId` equals the path value exactly. The frontend's `useCustomerPayments()` hook would pass the username, but no page uses it.

**Auth:** Bearer JWT; `{customerId}` must equal `X-Username`, or the caller is `ADMIN` (403 otherwise).

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `customerId` | path | string | yes | Exact match |

**Responses**

- `200 OK` with a JSON array of [`PaymentDTO`](#paymentdto). The array is empty when nothing matches; this endpoint never returns 404. The order is unspecified because the query has no `ORDER BY`.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/customer/alice"
```

## POST /api/v1/payments/{id}/process

Settles a `PENDING` payment with the simulated gateway: `ThreadLocalRandom.current().nextInt(10) < 8` gives exactly 80 % success. **A declined payment still returns 200**, so the caller must read `status`.

| Outcome | `status` | `transactionId` | `failureReason` | Event |
|---|---|---|---|---|
| Success (draw 0 to 7) | `COMPLETED` | `TXN-` followed by 8 upper-case hex digits | `null` | `payment.completed` |
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
    "transactionId": "TXN-1A2B3C4D",
    "failureReason": null,
    "cardLastFour": "4242",
    "createdAt": "2026-10-29T14:30:15.123456",
    "updatedAt": "2026-10-29T14:30:16.002931"
  }
  ```

- `404` with `Payment not found: {id}`.
- `409` with `Payment already in status: {status}` when the payment is not `PENDING`.

**Side effects:**

- Updates the `payments` row. The intermediate `PROCESSING` status is never committed.
- Publishes `payment.completed` or `payment.failed` with key `orderId`. The send happens inside the transaction, before commit, and is fire-and-forget.
- Downstream:
  - order-service sets the order to `PAID` or `CANCELLED`.
  - shipping-service creates a shipment on `payment.completed`.
  - notification-service logs a notification.

The payment row carries a `version` column (optimistic locking, migration `V3`), so two concurrent calls settle it once and publish once; the loser gets 409.

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
- Publishes `payment.refunded` with the full `amount` and key `orderId`, before commit.
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
