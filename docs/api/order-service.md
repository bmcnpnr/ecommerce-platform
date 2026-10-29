# Order Service API reference

Base URL through the gateway `http://localhost:8080`; direct (bypasses the gateway, dev only) `http://localhost:8084`.
Live OpenAPI from springdoc: `http://localhost:8084/api-docs`, Swagger UI `http://localhost:8084/swagger-ui.html`.

Service overview, lifecycle and events: [order-service](../services/order-service.md).

## Conventions

**Content type.**
- Request and response bodies are `application/json`.
- `GET /hello` is the exception: it returns plain text.
- Only `POST /{orderId}/items` takes a body. Unknown JSON properties in it are ignored (Jackson 3 default).
- Sending it with a non-JSON `Content-Type` fails with 500, not 415.

**Authentication.**
- At the gateway: every `/api/v1/orders/**` path needs `Authorization: Bearer <JWT>`, whatever the method; without
  it the gateway answers 401 with an empty body. The gateway adds `X-Username`, `X-User-Id` and `X-User-Role`.
- In the service: it reads none of those headers and has no Spring Security, so it performs **no authentication,
  role or ownership check**. `customerId` is whatever the caller sends.
- On port 8084 directly: no token is needed at all.

**Correlation.** `X-Correlation-Id` is taken from the request, or generated as a UUID. It is returned in the response
header of the same name and in every error body.

**Error body.** Every error produced by the service has this shape (`exception/ErrorResponse.java`). All seven keys
are always present, and `fieldErrors` is `null` except on bean-validation failures:

```json
{
  "correlationId": "3f6c1b8e-5d2a-4c1e-9b7a-2f0d8e4c6a11",
  "error": "Not Found",
  "fieldErrors": null,
  "message": "Order not found: 999",
  "path": "/api/v1/orders/999",
  "status": 404,
  "timestamp": "2026-10-29T18:07:12.345678"
}
```

**Exception to status mapping** (`exception/GlobalExceptionHandler.java`; the most specific handler wins):

| Cause | Status | `error` | `message` |
|---|---|---|---|
| `OrderNotFoundException` | 404 | `Not Found` | `Order not found: <orderId>` |
| `InvalidOrderStateException` (state rules, stock pre-check) | 400 | `Bad Request` | Rule-specific, listed per endpoint |
| `MethodArgumentNotValidException` (`@Valid` body) | 400 | `Bad Request` | `Validation failed`, plus `fieldErrors` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | Spring's message, e.g. `Request method 'GET' is not supported` |
| `MissingServletRequestParameterException`, other `ServletRequestBindingException`, `HttpMessageNotReadableException` (missing or malformed body), `MethodArgumentTypeMismatchException` (non-numeric id, unknown enum) | 400 | `Bad Request` | Spring's exception message |
| `FeignException` from product-service with status 404 / 400 / 409 | 404 / 400 / 409 | reason phrase | `Downstream service call failed: ` + Feign's message (method, internal URL, Feign method key, product-service's response body) |
| `FeignException` with status 503, or -1 (no response: connect failure after retries, read timeout) | 503 | `Service Unavailable` | same prefix |
| `FeignException` with any other status (500, 401, 422, ...) | 502 | `Bad Gateway` | same prefix |
| Other `RuntimeException` whose message contains `unavailable` | 503 | `Service Unavailable` | the exception message. Only the unwired Feign fallback throws such a message, so in practice this branch is not reached. |
| Any other `RuntimeException`, including an open circuit breaker (`CallNotPermittedException`), `KafkaException` on publish, database errors | 500 | `Internal Server Error` | `An unexpected error occurred` |
| Any other `Exception`, e.g. `HttpMediaTypeNotSupportedException` | 500 | `Internal Server Error` | `An unexpected error occurred` |

**Pagination.** None. The list endpoint returns a plain JSON array.

**Formats.**
- `LocalDateTime` values (`orderDate`, `timestamp`) are ISO-8601 strings with no offset, for example
  `"2026-10-29T18:07:12.345678"`. They are server-local time, which is UTC in the containers. (Jackson 3 defaults;
  the service sets no `spring.jackson.*`.)
- Money (`totalAmount`, `productPrice`) is a JSON number. Values read from PostgreSQL carry the `NUMERIC(19,4)`
  scale (`99.9800`); a freshly created order reports `"totalAmount": 0`.
- `status` is the enum name.
- Response properties come out in alphabetical order (Jackson 3 default).

**Examples** are for bash (Git Bash or WSL). PowerShell 5.1 strips the quotes inside JSON arguments to `curl.exe`.
They assume:

```bash
GW=http://localhost:8080
TOKEN=$(curl -s -X POST "$GW/api/v1/users/login" -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"Passw0rd!123"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
AUTH="Authorization: Bearer $TOKEN"
```

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| GET | `/api/v1/orders/hello` | Bearer JWT | none | Greeting text |
| POST | `/api/v1/orders` | Bearer JWT | none (`customerId` not validated or tied to the caller) | Create a PENDING order |
| GET | `/api/v1/orders/{orderId}` | Bearer JWT | none | Get an order |
| GET | `/api/v1/orders/customer/{customerId}` | Bearer JWT | none | List a customer's orders |
| POST | `/api/v1/orders/{orderId}/items` | Bearer JWT | status not CANCELLED/PAID; stock pre-check | Add a line, reserve stock |
| POST | `/api/v1/orders/{orderId}/products` | Bearer JWT | same as `/items`, but no quantity validation | Legacy add-line |
| POST | `/api/v1/orders/{orderId}/confirm` | Bearer JWT | status PENDING; at least one item | Confirm, publish `order.placed` |
| PATCH | `/api/v1/orders/{orderId}/status` | Bearer JWT | none (any transition) | Set status |
| DELETE | `/api/v1/orders/{orderId}` | Bearer JWT | status not SHIPPED/DELIVERED | Cancel, return stock, publish `order.cancelled` |

## GET /api/v1/orders/hello

Returns a fixed greeting, left over from the service's scaffolding.

**Auth:** Bearer JWT at the gateway; no service-side checks.

**Responses**
- `200 OK`, `text/plain`: `Hello from Order Service!`

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/orders/hello"
```

## POST /api/v1/orders

Creates an empty order in status PENDING with `totalAmount` 0 and `orderDate` now. The frontend treats it as the
shopping cart.

**Auth:** Bearer JWT at the gateway; no service-side checks. The order belongs to whatever `customerId` the caller
passes. The frontend passes the logged-in username; the smoke test passes `1`.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `customerId` | query | string | yes | — | None. A blank value is accepted. More than 255 characters fails at the database (500). |

**Request body:** none. A body is ignored.

**Responses**
- `201 Created`, [`OrderDTO`](#orderdto). There is no `Location` header.

  ```json
  {
    "billingAddress": null,
    "customerId": "alice",
    "orderDate": "2026-10-29T18:07:12.345678",
    "orderId": 42,
    "orderItems": [],
    "shippingAddress": null,
    "status": "PENDING",
    "totalAmount": 0
  }
  ```
- `400`: `customerId` missing (`Required request parameter 'customerId' for method parameter type String is not present`).
- `500`: database error.

**Side effects:** INSERT into `orders`. No events, no Feign calls.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/orders?customerId=alice"
```

## GET /api/v1/orders/{orderId}

Returns one order with its lines.

**Auth:** Bearer JWT at the gateway; no service-side checks. Any caller can read any order.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |

**Responses**
- `200 OK`, [`OrderDTO`](#orderdto):

  ```json
  {
    "billingAddress": null,
    "customerId": "alice",
    "orderDate": "2026-10-29T18:07:12.345678",
    "orderId": 42,
    "orderItems": [
      {
        "orderId": 42,
        "orderItemId": 57,
        "productId": 7,
        "productName": "Wireless Mouse",
        "productPrice": 49.9900,
        "quantity": 2
      }
    ],
    "shippingAddress": null,
    "status": "CONFIRMED",
    "totalAmount": 99.9800
  }
  ```
- `404`: `Order not found: <orderId>`.
- `400`: non-numeric `orderId`.

**Side effects:** none (read-only transaction).

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/orders/42"
```

## GET /api/v1/orders/customer/{customerId}

Lists every order stored under `customerId`, in all statuses, including the CANCELLED orders the frontend leaves
behind when it removes a cart item.

**Auth:** Bearer JWT at the gateway; no service-side checks. Any caller can list any customer's orders.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `customerId` | path | string | yes | — | Matched exactly against `orders.customer_id` |

**Responses**
- `200 OK`: a JSON array of [`OrderDTO`](#orderdto). The array is empty if nothing matches (never 404), has no
  pagination and comes in no defined order.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/orders/customer/alice"
```

## POST /api/v1/orders/{orderId}/items

Adds one line to the order. The service reads the product from product-service, rejects the request if the reported
stock is lower than `quantity`, and reserves the stock by sending `PATCH /api/v1/products/{productId}/stock` with
`{"delta": -quantity}`. It then copies the product's current `name` and `price` into a new line and adds
`price × quantity` to `totalAmount`. The same product added twice gives two lines. There is no endpoint to remove a
line or change its quantity.

**Auth:** Bearer JWT at the gateway. Service-side: no identity checks; status rule below.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |

**Request body** [`AddItemRequest`](#additemrequest)

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `productId` | integer (int64) | yes | `@NotNull` "Product ID is required" | product-service product id |
| `quantity` | integer (int32) | yes | `@NotNull` "Quantity is required", `@Min(1)` "Quantity must be at least 1" | No upper bound |

```json
{ "productId": 7, "quantity": 2 }
```

**Responses** (checked in this order)
- `200 OK` (not 201), the updated [`OrderDTO`](#orderdto):

  ```json
  {
    "billingAddress": null,
    "customerId": "alice",
    "orderDate": "2026-10-29T18:07:12.345678",
    "orderId": 42,
    "orderItems": [
      {
        "orderId": 42,
        "orderItemId": 57,
        "productId": 7,
        "productName": "Wireless Mouse",
        "productPrice": 49.9900,
        "quantity": 2
      }
    ],
    "shippingAddress": null,
    "status": "PENDING",
    "totalAmount": 99.9800
  }
  ```
- `400`: body validation failed. This is checked before the order is looked up.

  ```json
  {
    "correlationId": "3f6c1b8e-5d2a-4c1e-9b7a-2f0d8e4c6a11",
    "error": "Bad Request",
    "fieldErrors": [ { "field": "quantity", "message": "Quantity must be at least 1" } ],
    "message": "Validation failed",
    "path": "/api/v1/orders/42/items",
    "status": 400,
    "timestamp": "2026-10-29T18:07:12.345678"
  }
  ```
- `400`: body missing or malformed JSON.
- `404`: `Order not found: <orderId>`.
- `400`: `Cannot add items to order in status: CANCELLED` (or `PAID`). CONFIRMED, SHIPPED and DELIVERED orders
  **accept** items.
- `404`: product unknown to product-service (`Downstream service call failed: ...`). The smoke test asserts this.
- `400`: `Insufficient stock for product <sku>. Available: <n>`, from order-service's own pre-check.
- `400`: product-service refused the reservation because stock would go below zero
  (`Downstream service call failed: ...Insufficient stock...`).
- `503`: product-service unreachable after 3 connection attempts, read timeout (10 s), or no instance registered.
- `502`: product-service answered 5xx or another unexpected status.
- `500`: product-service circuit breaker OPEN, a database error, or a non-JSON `Content-Type`.

**Side effects**
- Feign `GET /api/v1/products/{productId}`, then `PATCH /api/v1/products/{productId}/stock` with `{"delta": -quantity}`.
- The reservation is **not** undone if a later step fails. A read timeout on a PATCH that product-service did apply
  returns 503 with the stock still reserved.
- INSERT into `order_items` and UPDATE of `orders`. No events.

**Example**

```bash
curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"productId":7,"quantity":2}' "$GW/api/v1/orders/42/items"
```

## POST /api/v1/orders/{orderId}/products

Legacy form of [add item](#post-apiv1ordersorderiditems) that takes query parameters instead of a body ("use /items
instead" in its OpenAPI summary). It calls the same `OrderService.addItemToOrder()`, so the responses and side
effects are the same, but **`quantity` is not validated**. Zero is accepted. A negative quantity passes the stock
pre-check, sends a positive `delta` (which increases product stock) and adds a line with a negative amount to
`totalAmount`.

**Auth:** Bearer JWT at the gateway; no service-side identity checks.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |
| `productId` | query | integer (int64) | yes | — | Missing or non-numeric: 400 |
| `quantity` | query | integer (int32) | no | `1` | None |

**Request body:** none.

**Responses:** as for `/items`, minus the body-validation 400; missing `productId` gives 400.

**Side effects:** as for `/items`.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/orders/42/products?productId=7&quantity=1"
```

## POST /api/v1/orders/{orderId}/confirm

Moves a PENDING order with at least one line to CONFIRMED and publishes `order.placed`. The frontend then creates and
processes the payment in payment-service. The payment result comes back over Kafka and sets PAID or CANCELLED.

**Auth:** Bearer JWT at the gateway; no service-side identity checks.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |

**Request body:** none.

**Responses**
- `200 OK`: [`OrderDTO`](#orderdto) with `"status": "CONFIRMED"`.
- `404`: `Order not found: <orderId>`.
- `400`: `Can only confirm PENDING orders. Current status: <STATUS>`.
- `400`: `Cannot confirm an order with no items`.
- `500`: the Kafka publish failed immediately (`KafkaException`). For example, when the broker metadata is
  unavailable the request blocks for up to 60 s (`max.block.ms`) first. The order stays PENDING because the
  transaction rolls back.

**Side effects**
- UPDATE of `orders.status`.
- Publishes `order.placed` (key `orderId`) **inside** the transaction, before commit. The payload is in the
  [service doc](../services/order-service.md#orderplaced).
- No Feign calls.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/orders/42/confirm"
```

## PATCH /api/v1/orders/{orderId}/status

Overwrites the status. The OpenAPI summary calls it "admin/internal", but nothing restricts it. It is the only way to
reach SHIPPED and DELIVERED, and the frontend's admin order page uses it.

**Auth:** Bearer JWT at the gateway; **no service-side checks**, no role check, no transition validation. Any status
can be set from any status, including reviving a CANCELLED order or marking an unpaid order PAID.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |
| `status` | query | string enum | yes | — | `PENDING`, `CONFIRMED`, `PAID`, `SHIPPED`, `DELIVERED`, `CANCELLED`; any other value is 400 |

**Request body:** none.

**Responses**
- `200 OK`: the updated [`OrderDTO`](#orderdto).
- `404`: `Order not found: <orderId>`.
- `400`: `status` missing or not an enum name.

**Side effects:** UPDATE of `orders.status` only. Setting CANCELLED here returns **no** stock and publishes **no**
`order.cancelled`; setting PAID publishes nothing.

**Example**

```bash
curl -s -X PATCH -H "$AUTH" "$GW/api/v1/orders/42/status?status=SHIPPED"
```

## DELETE /api/v1/orders/{orderId}

Cancels the order; nothing is deleted. The service:
1. sets CANCELLED;
2. for every line, sends `PATCH /api/v1/products/{productId}/stock` with `{"delta": +quantity}` to product-service;
3. publishes `order.cancelled`.

The frontend shows the Cancel button only for PENDING and CONFIRMED orders, but the API also cancels PAID orders,
without refunding them, and orders that are already CANCELLED.

**Auth:** Bearer JWT at the gateway; no service-side identity checks.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |

**Request body:** none.

**Responses**
- `204 No Content`.
- `404`: `Order not found: <orderId>`.
- `400`: `Cannot cancel order in status: SHIPPED` (or `DELIVERED`).
- `500`: the Kafka publish failed immediately. The transaction rolls back, but the stock restores have already been
  sent.

**Side effects**
- UPDATE of `orders.status`.
- One Feign PATCH per line. Failures are logged and ignored, so stock may stay reserved while the cancel still
  returns 204.
- Publishes `order.cancelled` (key `orderId`) inside the transaction.
- Calling DELETE again on a CANCELLED order repeats the stock restores and the event.

**Example**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE -H "$AUTH" "$GW/api/v1/orders/42"
```

## Schemas

### OrderDTO

`dto/OrderDTO.java`. Returned by every endpoint except `/hello` and `DELETE`.

| Field | Type | Nullable | Notes |
|---|---|---|---|
| `orderId` | integer (int64) | no | |
| `customerId` | string | no | As supplied at creation |
| `orderItems` | array of [`OrderItemDTO`](#orderitemdto) | no | Empty for a new order |
| `orderDate` | string (ISO-8601 local date-time) | no | Creation time |
| `billingAddress` | string | yes | Always `null`: no endpoint sets it |
| `shippingAddress` | string | yes | Always `null`: no endpoint sets it |
| `totalAmount` | number | no | Sum of `productPrice × quantity` over the lines |
| `status` | string | no | `PENDING`, `CONFIRMED`, `PAID`, `SHIPPED`, `DELIVERED`, `CANCELLED` |

### OrderItemDTO

`dto/OrderItemDTO.java`.

| Field | Type | Nullable | Notes |
|---|---|---|---|
| `orderItemId` | integer (int64) | no | |
| `orderId` | integer (int64) | no | Parent order id (no nested order) |
| `productId` | integer (int64) | no | product-service id |
| `productName` | string | yes | Product name at add time |
| `productPrice` | number | yes | Unit price at add time |
| `quantity` | integer (int32) | no | |

### AddItemRequest

`dto/AddItemRequest.java`. Body of `POST /{orderId}/items`.

| Field | Type | Required | Validation |
|---|---|---|---|
| `productId` | integer (int64) | yes | `@NotNull(message = "Product ID is required")` |
| `quantity` | integer (int32) | yes | `@NotNull(message = "Quantity is required")`, `@Min(value = 1, message = "Quantity must be at least 1")` |

### ErrorResponse

`exception/ErrorResponse.java`.

| Field | Type | Nullable | Notes |
|---|---|---|---|
| `timestamp` | string (ISO-8601 local date-time) | no | |
| `status` | integer | no | HTTP status code |
| `error` | string | no | Reason phrase |
| `message` | string | yes | See the mapping table |
| `path` | string | no | Request URI |
| `correlationId` | string | no | Same value as the `X-Correlation-Id` response header |
| `fieldErrors` | array of `FieldError` | yes | Only on `Validation failed` |

`FieldError`: `field` (string, the request-body property), `message` (string, the constraint message).
