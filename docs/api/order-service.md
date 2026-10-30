# Order Service API reference

Base URL through the gateway `http://localhost:8080`; direct (bypasses the gateway, dev only) `http://localhost:8084`.
Live OpenAPI from springdoc: `http://localhost:8084/api-docs`, Swagger UI `http://localhost:8084/swagger-ui.html`.

Service overview, lifecycle and events: [order-service](../services/order-service.md).

## Conventions

**Content type.**
- Request and response bodies are `application/json`.
- `GET /hello` is the exception: it returns plain text.
- Only `POST /{orderId}/items` takes a body. Unknown JSON properties in it are ignored (Jackson 3 default).
- Sending it with a non-JSON `Content-Type` fails with 415.

**Authentication.**
- At the gateway: every `/api/v1/orders/**` path needs `Authorization: Bearer <JWT>`, whatever the method; without
  it the gateway answers 401 with an empty body. The gateway adds `X-Username`, `X-User-Id` and `X-User-Role`.
- In the service: ownership is `customerId` against `X-Username`. Missing identity is 401 `Authentication required`;
  another customer's order is 403 `Access denied`; the role must be exactly `ADMIN` for the admin exceptions.
  `PATCH /status` is admin-only (also 403 at the gateway). `customerId` defaults to `X-Username`.
- On port 8084 directly: no token, so whoever calls chooses the identity headers. `/internal/v1/orders/{id}` is
  service-to-service and never routed by the gateway.
- Every response carries `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.

**Correlation.** `X-Correlation-Id` is taken from the request if it matches `^[A-Za-z0-9._-]{1,64}$`, otherwise generated as a UUID. It is returned in the response
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
| missing identity | 401 | `Unauthorized` | `Authentication required` |
| not the owner / not `ADMIN` | 403 | `Forbidden` | `Access denied` |
| `IllegalStatusTransitionException` (`PATCH /status`) | 409 | `Conflict` | `Cannot change order status from <A> to <B>` |
| `OptimisticLockingFailureException` (another request changed the same order first: add item, confirm, cancel, status) | 409 | `Conflict` | `The order was modified by another request` |
| `BadRequestException` (`customerId`, `quantity`, `page`, `size`) | 400 | `Bad Request` | e.g. `quantity must be between 1 and 1000`, `page must be at least 0 and size between 1 and 100` |
| `UpstreamDataException` (missing or non-positive product price) | 502 | `Bad Gateway` | `Product price is not available` |
| `InvalidOrderStateException` (state rules, line and total limits, stock pre-check) | 400 | `Bad Request` | Rule-specific, listed per endpoint |
| `MethodArgumentNotValidException` (`@Valid` body) | 400 | `Bad Request` | `Validation failed`, plus `fieldErrors` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | `Request method not supported` |
| `HttpMediaTypeNotSupportedException` / not acceptable / unmapped path | 415 / 406 / 404 | | `Unsupported content type` / `Requested media type not acceptable` / `Resource not found` |
| `MissingServletRequestParameterException`, other `ServletRequestBindingException`, `HttpMessageNotReadableException` (missing or malformed body), `MethodArgumentTypeMismatchException` (non-numeric id, unknown enum) | 400 | `Bad Request` | `Malformed request body`, `Invalid value for parameter '<name>'`, `Missing required parameter '<name>'` or `Invalid request` |
| `FeignException` from product-service with status 404 / 400 / 409 | 404 / 400 / 409 | reason phrase | `Downstream service call failed: resource not found` / `request rejected` |
| `FeignException` with status 503, or -1 (no response: connect failure after retries, read timeout), and an open product-service circuit breaker (`CallNotPermittedException`) | 503 | `Service Unavailable` | `Downstream service call failed: service unavailable` |
| `FeignException` with any other status (500, 401, 422, ...) | 502 | `Bad Gateway` | `Downstream service call failed` |
| A dependency of this service does not answer: the database (connection wait over 5 s, lock timeout, a connection lost during commit or rollback), a Kafka timeout | 503 | `Service Unavailable` | `Service temporarily unavailable` |
| Any other `RuntimeException` | 500 | `Internal Server Error` | `An unexpected error occurred` |
| Any other `Exception` | 500 | `Internal Server Error` | `An unexpected error occurred` |

A 503 writes one WARN per exception class per 10 s, with the root cause and no stack trace. A 500 writes one ERROR with its stack trace per failure site per 10 s.

**Pagination.** Only the customer's order list is paged: optional `page` (from 0, default 0) and `size` (1 to 100, default 100), newest first (by order id, descending). It still returns a plain JSON array, so a client that sends no parameter gets the newest 100 orders. A `page` below 0 or a `size` outside 1 to 100 is 400, not clamped.

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
  -d '{"username":"alice","password":"<alice password>"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
AUTH="Authorization: Bearer $TOKEN"
ADMIN_AUTH="Authorization: Bearer $ADMIN_TOKEN"   # login as admin with ADMIN_PASSWORD from ecommerce-platform/.env
```

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| GET | `/api/v1/orders/hello` | Bearer JWT | authenticated | Greeting text |
| POST | `/api/v1/orders` | Bearer JWT | `customerId` is the caller, or any for `ADMIN`; validated | Create a PENDING order |
| GET | `/api/v1/orders/{orderId}` | Bearer JWT | owner or `ADMIN` | Get an order |
| GET | `/api/v1/orders/customer/{customerId}` | Bearer JWT | that customer or `ADMIN`; `page` at least 0, `size` 1 to 100 | List a customer's orders, newest first |
| POST | `/api/v1/orders/{orderId}/items` | Bearer JWT | owner or `ADMIN`; status PENDING; quantity 1 to 1000; at most 200 lines; total at most 999999999999999.9999; stock pre-check | Add a line, reserve stock |
| POST | `/api/v1/orders/{orderId}/products` | Bearer JWT | same as `/items` | Legacy add-line |
| POST | `/api/v1/orders/{orderId}/confirm` | Bearer JWT | owner or `ADMIN`; status PENDING; at least one item | Confirm, publish `order.placed` (through the outbox) |
| PATCH | `/api/v1/orders/{orderId}/status` | `ADMIN` | `ADMIN`; transition table (409) | Set status |
| DELETE | `/api/v1/orders/{orderId}` | Bearer JWT | owner or `ADMIN`; status not CANCELLED/SHIPPED/DELIVERED | Cancel, publish `order.cancelled` (through the outbox), then return stock |
| GET | `/internal/v1/orders/{orderId}` | not routed | none | The `OrderDTO`, for payment-service's order check |

## GET /api/v1/orders/hello

Returns a fixed greeting, left over from the service's scaffolding.

**Auth:** Bearer JWT at the gateway.

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

**Auth:** Bearer JWT; 401 without identity. `customerId` defaults to `X-Username`; a non-admin who names another
customer gets 403. The frontend passes the logged-in username.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `customerId` | query | string | no | `X-Username` | Not blank, at most 255 characters, no control characters or other invalid characters (400). |

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
- `400`: `customerId` blank or invalid.
- `401` / `403`: no identity / another customer's name.

**Side effects:** INSERT into `orders`. No events, no Feign calls.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/orders?customerId=alice"
```

## GET /api/v1/orders/{orderId}

Returns one order with its lines.

**Auth:** owner (`customerId` equals `X-Username`) or `ADMIN`; otherwise 403. An unknown order is 404.

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

Lists the orders stored under `customerId`, in all statuses, including the CANCELLED orders the frontend leaves
behind when it removes a cart item and the carts the expiry job cancelled. Newest first, one page at a time.

**Auth:** `{customerId}` must equal `X-Username`, or the caller is `ADMIN`; otherwise 403. The check comes before the
`page` and `size` validation.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `customerId` | path | string | yes | — | Matched exactly against `orders.customer_id` |
| `page` | query | integer (int32) | no | `0` | At least 0, else 400 |
| `size` | query | integer (int32) | no | `100` | 1 to 100, else 400 (a larger value is rejected, not clamped) |

**Responses**
- `200 OK`: a JSON array of [`OrderDTO`](#orderdto), at most `size` long, ordered by `orderId` descending (newest first).
  The array is empty if nothing matches or the page is past the end (never 404). It is still a plain array: to read
  further back, ask for `page=1`, `page=2` and so on until a page comes back shorter than `size`.
- `400`: `page must be at least 0 and size between 1 and 100`, or a non-numeric `page` or `size` (`Invalid value for
  parameter 'size'`).

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/orders/customer/alice?page=0&size=20"
```

## POST /api/v1/orders/{orderId}/items

Adds one line to the order. The service reads the product from product-service, rejects the request if the reported
stock is lower than `quantity`, and reserves the stock by sending `PATCH /internal/v1/products/{productId}/stock` with
`{"delta": -quantity}`. It then copies the product's current `name` and `price` into a new line and adds
`price × quantity` to `totalAmount`. The same product added twice gives two lines. There is no endpoint to remove a
line or change its quantity.

**Auth:** owner or `ADMIN`; status rule below.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |

**Request body** [`AddItemRequest`](#additemrequest)

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `productId` | integer (int64) | yes | `@NotNull` "Product ID is required" | product-service product id |
| `quantity` | integer (int32) | yes | `@NotNull` "Quantity is required", `@Min(1)` "Quantity must be at least 1", `@Max(1000)` "Quantity must be at most 1000" | Integer only: a fractional or string value is 400 |

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
- `400`: `Cannot add items to order in status: <STATUS>`. Only PENDING orders accept items.
- `400`: `An order can have at most 200 lines`. Checked before any call to product-service.
- `404`: product unknown to product-service (`Downstream service call failed: resource not found`). The smoke test
  asserts this.
- `503`: product-service gave no answer: unreachable after 3 connection attempts, read timeout (10 s), no instance
  registered, or its circuit breaker is open (`Downstream service call failed: service unavailable`).
- `502`: product-service answered 5xx or another unexpected status, or returned a missing or non-positive price
  (`Product price is not available`); no stock moves.
- `400`: `The order total is too large`. The line would take `totalAmount` above 999999999999999.9999 (the limit of
  `NUMERIC(19,4)`); no stock moves.
- `400`: `Insufficient stock for product <sku>. Available: <n>`, from order-service's own pre-check.
- `400`: product-service refused the reservation because stock would go below zero
  (`Downstream service call failed: request rejected`).
- `409`: `The order was modified by another request`. Another request changed the order between the read and the save;
  the reservation is released again.
- `503`: `Service temporarily unavailable`. The database did not answer when the line was saved; the reservation is
  released again.
- `415`: non-JSON `Content-Type` (answered before any of the above).

**Side effects**
- Feign `GET /api/v1/products/{productId}`, then `PATCH /internal/v1/products/{productId}/stock` with `{"delta": -quantity}`.
  No database transaction is open during either call.
- The line is then saved in its own short transaction: INSERT into `order_items` and UPDATE of `orders` (which also moves
  `updated_at`, so a cart in use does not expire). If that save fails, the reservation is released with
  `{"delta": +quantity}`, once. If the PATCH itself times out, product-service may or may not have applied it: nothing
  is released, the client gets 503 and a retry can reserve a second time.
- No events.

**Example**

```bash
curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"productId":7,"quantity":2}' "$GW/api/v1/orders/42/items"
```

## POST /api/v1/orders/{orderId}/products

Legacy form of [add item](#post-apiv1ordersorderiditems) that takes query parameters instead of a body ("use /items
instead" in its OpenAPI summary). It calls the same `OrderService.addItemToOrder()`, so the responses and side
effects are the same, and `quantity` must be an integer from 1 to 1000 (400 otherwise).

**Auth:** owner or `ADMIN`.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |
| `productId` | query | integer (int64) | yes | — | Missing or non-numeric: 400 |
| `quantity` | query | integer (int32) | no | `1` | 1 to 1000 |

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

**Auth:** owner or `ADMIN`.

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
- `409`: `The order was modified by another request` (another request changed the order at the same moment).
- `503`: `Service temporarily unavailable`, when the database does not answer. A Kafka outage does not reach this
  endpoint: the event waits in the outbox.

**Side effects**
- UPDATE of `orders.status`, and an INSERT into `outbox_event` for `order.placed` (key `orderId`) in the **same**
  transaction. The relay publishes it to Kafka about half a second after the commit, at least once. If the transaction
  rolls back, nothing is published. The payload is in the [service doc](../services/order-service.md#orderplaced).
- No Feign calls.

**Example**

```bash
curl -s -X POST -H "$AUTH" "$GW/api/v1/orders/42/confirm"
```

## PATCH /api/v1/orders/{orderId}/status

Moves the order along the allowed transitions. It is the only way to reach SHIPPED and DELIVERED, and the frontend's
admin order page uses it.

**Auth:** `ADMIN` only (403 at the gateway and in the service). Allowed moves: PENDING to CONFIRMED or CANCELLED;
CONFIRMED to PAID or CANCELLED; PAID to SHIPPED or CANCELLED; SHIPPED to DELIVERED. Anything else is 409.

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
- `409`: `Cannot change order status from <A> to <B>`, or `The order was modified by another request`.

**Side effects:** UPDATE of `orders.status`. Setting CANCELLED or CONFIRMED runs the same code as the customer endpoints
(`order.cancelled` through the outbox, then the stock goes back; or `order.placed` through the outbox); setting PAID or
SHIPPED publishes nothing.

**Example**

```bash
# needs an admin token (ADMIN_PASSWORD from ecommerce-platform/.env)
curl -s -X PATCH -H "$ADMIN_AUTH" "$GW/api/v1/orders/42/status?status=SHIPPED"
```

## DELETE /api/v1/orders/{orderId}

Cancels the order; nothing is deleted. The service:
1. sets CANCELLED and writes `order.cancelled` to the outbox, in one transaction, and commits;
2. after the commit, for every line, sends `PATCH /internal/v1/products/{productId}/stock` with `{"delta": +quantity}`
   to product-service, outside any transaction. The first answer that means "product-service is not there" (no
   connection, a timeout, 503, an open breaker) ends the loop;
3. returns 204. The relay publishes `order.cancelled` to Kafka about half a second after the commit.

The frontend shows the Cancel button only for PENDING and CONFIRMED orders, but the API also cancels PAID orders,
without refunding them.

**Auth:** owner or `ADMIN`.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `orderId` | path | integer (int64) | yes | — | Numeric, else 400 |

**Request body:** none.

**Responses**
- `204 No Content`.
- `404`: `Order not found: <orderId>`.
- `400`: `Cannot cancel order in status: CANCELLED` (or `SHIPPED`, `DELIVERED`).
- `409`: `The order was modified by another request`. Of two cancels at the same moment, the later commit fails on the
  order's version and never reaches the stock.
- `503`: `Service temporarily unavailable`, when the database does not answer. A product-service outage does **not**
  fail the cancel (see below), and neither does a Kafka outage.

**Side effects**
- UPDATE of `orders.status` and an INSERT into `outbox_event` for `order.cancelled` (key `orderId`), in one transaction.
- One Feign PATCH per line, after the commit. A failure never undoes the cancellation: the response is still 204, and
  if product-service did not answer, one WARN (at most one per 10 s) names the lines whose stock was not returned. A call
  that timed out has an unknown outcome and is not repeated.
- Calling DELETE again on a CANCELLED order is `400`; stock is restored once.

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
| `quantity` | integer (int32) | yes | `@NotNull(message = "Quantity is required")`, `@Min(1)`, `@Max(1000)` |

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
