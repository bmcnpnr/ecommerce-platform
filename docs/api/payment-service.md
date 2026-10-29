# Payment service API reference

Call the API through the gateway at `http://localhost:8080`. The service also listens directly on `http://localhost:8085`, which bypasses the gateway and its JWT check; use that for development only.

- **Try it:** the platform Swagger UI at `http://localhost:8080/swagger-ui.html`, entry `payment-service`. Calls go through the gateway, so click **Authorize** with a token from `POST /api/v1/users/login` first.
- **OpenAPI document:** `http://localhost:8080/api-docs/payment-service` (through the gateway), `http://localhost:8085/api-docs` (direct), or the committed snapshot [openapi/payment-service.json](openapi/payment-service.json).

Service overview: [payment-service](../services/payment-service.md).

## Conventions

- **Content type:** request and response bodies are `application/json`. A body sent with any other `Content-Type` raises `HttpMediaTypeNotSupportedException`, which ends in the catch-all handler as 500.
- **Authentication:** every path needs `Authorization: Bearer <JWT>` at the gateway. Without a valid token the gateway answers 401 with an empty body, and the request never reaches the service. The service itself checks nothing: it reads no `X-User-*` header and applies no role or ownership rule.
- **Correlation:** every response carries `X-Correlation-Id`. The service reuses the incoming value or generates a UUID.
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
| `PaymentAlreadyProcessedException` | 409 | `Conflict` | `Payment already completed for order: {orderId}` or `Payment already in status: {status}` |
| `InvalidPaymentStateException` | 400 | `Bad Request` | `Can only refund COMPLETED payments. Current: {status}` |
| `MethodArgumentNotValidException` (`@Valid` body) | 400 | `Bad Request` | `Validation failed`, with `fieldErrors` |
| `HttpMessageNotReadableException` (missing or malformed body), `MethodArgumentTypeMismatchException` (for example a non-numeric `{id}`), `MissingServletRequestParameterException`, `ServletRequestBindingException` | 400 | `Bad Request` | The exception's own message |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | The exception's own message |
| Anything else, including `IllegalArgumentException` from an unknown `method`, `IncorrectResultSizeDataAccessException` when an order has two payments, `NoResourceFoundException` for an unknown path, and database errors | 500 | `Internal Server Error` | `An unexpected error occurred`, logged at ERROR with the stack trace |

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/payments` | Bearer JWT | None | Create a `PENDING` payment |
| GET | `/api/v1/payments/{id}` | Bearer JWT | None | Get a payment by id |
| GET | `/api/v1/payments/order/{orderId}` | Bearer JWT | None | Get the payment of an order |
| GET | `/api/v1/payments/customer/{customerId}` | Bearer JWT | None | List a customer's payments |
| POST | `/api/v1/payments/{id}/process` | Bearer JWT | None | Settle with the simulated gateway (80 % success) |
| POST | `/api/v1/payments/{id}/refund` | Bearer JWT | None | Refund a `COMPLETED` payment in full |

The examples below assume `GW=http://localhost:8080` and `AUTH="Authorization: Bearer $TOKEN"`. The api-test skill (`.claude/skills/api-test/SKILL.md`) shows how to get a token.

## POST /api/v1/payments

Creates a payment in `PENDING` for an order. The service stores the request as-is. It does not check whether the order exists, who owns it, what status it has or what its total is. The frontend checkout sends the order's `totalAmount` and the username as `customerId`. Creating a payment does not settle it; call [process](#post-apiv1paymentsidprocess) next.

**Auth:** Bearer JWT. No service-side checks.

**Request body** `InitiatePaymentRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `orderId` | integer (`Long`) | yes | `@NotNull` | Not verified against order-service |
| `customerId` | string | yes | `@NotBlank` | Stored as-is. The database allows at most 255 characters; longer values fail with 500 |
| `amount` | number (`BigDecimal`) | yes | `@NotNull`, `@DecimalMin("0.01")` (inclusive) | Stored as `NUMERIC(19,4)`, so extra decimals are rounded by PostgreSQL |
| `currency` | string | no | `@Size(max = 3)` | Defaults to `USD`. Any string of 3 characters or fewer is accepted, including `""` |
| `method` | string | yes | `@NotBlank` | Must be the exact enum name: `CREDIT_CARD`, `DEBIT_CARD`, `BANK_TRANSFER` or `DIGITAL_WALLET`. Anything else gives 500 |
| `cardLastFour` | string | no | `@Size(max = 4)` | Not checked to be digits |

The default validation messages are `must not be null`, `must not be blank`, `must be greater than or equal to 0.01` and `size must be between 0 and 3` (or `4` for `cardLastFour`).

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
- `409` with `Payment already completed for order: {orderId}` when the order's existing payment is `COMPLETED`. An existing `PENDING`, `FAILED` or `REFUNDED` payment does not block a new one.
- `500` for:
  - a `method` that is not an enum name;
  - an order that already has two or more payments, because the duplicate lookup itself fails;
  - values that overflow a database column.

**Side effects:** inserts one `payments` row. No event is published.

**Example**

```bash
curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"orderId":7,"customerId":"alice","amount":99.98,"currency":"USD","method":"CREDIT_CARD","cardLastFour":"4242"}' \
  "$GW/api/v1/payments"
```

## GET /api/v1/payments/{id}

Returns one payment.

**Auth:** Bearer JWT. No service-side checks: any caller can read any payment.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric; anything else gives 400 |

**Responses**

- `200 OK` with a [`PaymentDTO`](#paymentdto).
- `404` with `Payment not found: {id}`.
- `400` when `id` is not numeric.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/12"
```

## GET /api/v1/payments/order/{orderId}

Returns the payment of an order. The frontend's `OrderDetailPage` uses this endpoint.

**Auth:** Bearer JWT. No service-side checks.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `orderId` | path | integer (`Long`) | yes | Numeric |

**Responses**

- `200 OK` with a [`PaymentDTO`](#paymentdto).
- `404` with `Payment not found for order: {orderId}`.
- `500` when the order has more than one payment (for example a declined payment followed by a new one). `findByOrderId()` returns a single `Optional` and fails on two rows.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/payments/order/7"
```

## GET /api/v1/payments/customer/{customerId}

Lists every payment whose `customerId` equals the path value exactly. The frontend's `useCustomerPayments()` hook would pass the username, but no page uses it.

**Auth:** Bearer JWT. No service-side checks: any caller can list any customer's payments.

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

**Auth:** Bearer JWT. No service-side checks.

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

The endpoint takes no lock, so two concurrent calls on the same `PENDING` payment can both settle it and both publish.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/payments/12/process"
```

## POST /api/v1/payments/{id}/refund

Refunds a `COMPLETED` payment in full. The endpoint takes no amount, so partial refunds are not possible. The status becomes `REFUNDED`, which is terminal, and `transactionId` is kept.

No service and no frontend page calls this endpoint. The `useRefundPayment()` hook exists in the frontend but is unused.

**Auth:** Bearer JWT. No service-side checks: any caller can refund any completed payment.

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
curl -s -X POST -H "$AUTH" "$GW/api/v1/payments/12/refund"
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
