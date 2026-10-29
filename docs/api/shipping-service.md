# Shipping service API reference

Call the API through the gateway at `http://localhost:8080`. The service also listens directly on `http://localhost:8086`, which bypasses the gateway and its JWT check; use that for development only.

- **Try it:** the platform Swagger UI at `http://localhost:8080/swagger-ui.html`, entry `shipping-service`. Calls go through the gateway, so click **Authorize** with a token from `POST /api/v1/users/login` first (only tracking is public).
- **OpenAPI document:** `http://localhost:8080/api-docs/shipping-service` (through the gateway), `http://localhost:8086/api-docs` (direct), or the committed snapshot [openapi/shipping-service.json](openapi/shipping-service.json).

Service overview: [shipping-service](../services/shipping-service.md).

## Conventions

- **Content type:** request and response bodies are `application/json`. The only exception is `GET /hello`, which returns `text/plain`.
- **Authentication:**
  - `GET /api/v1/shipments/tracking/{trackingNumber}` is public at the gateway (`GET` only).
  - Every other path needs `Authorization: Bearer <JWT>`. Without a valid token the gateway answers 401 with an empty body.
  - `POST /api/v1/shipments` and `PATCH /{id}/status` are admin-only: 403 at the gateway unless the role is exactly `ADMIN`, and the service checks again (`401 Authentication required` without `X-Username`, `403 Access denied`).
  - Reads by order and history are owner-or-admin: the shipment's `customerId` must equal `X-Username`, otherwise 403.
  - Responses carry `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.
- **Correlation:** every response carries `X-Correlation-Id`. The service reuses the incoming value if it matches `^[A-Za-z0-9._-]{1,64}$`, otherwise generates a UUID.
- **Dates:** REST uses Spring Boot 4's Jackson 3 defaults (no `spring.jackson.*` settings and no custom mapper). `LocalDateTime` is written as an ISO-8601 local date-time string without zone, for example `2026-11-03T14:30:15.123456`. That includes `estimatedDelivery`, which is a date-time, not a date. Kafka events use a different form (integer arrays); see the [service page](../services/shipping-service.md#events).
- **Enums** are sent as their names. Shipment `status` is one of `PENDING`, `PROCESSING`, `SHIPPED`, `OUT_FOR_DELIVERY`, `DELIVERED` or `RETURNED`.
- **Pagination:** none. The history endpoint returns a plain JSON array.

### Error body

`exception/GlobalExceptionHandler.java` writes every error as an `ErrorResponse`:

```json
{
  "timestamp": "2026-10-29T14:31:02.481516",
  "status": 404,
  "error": "Not Found",
  "message": "Shipment not found: TRACK-00000000-0",
  "path": "/api/v1/shipments/tracking/TRACK-00000000-0",
  "correlationId": "5b0c7a2e-3f1d-4c8e-9a4b-1f2e3d4c5b6a",
  "fieldErrors": null
}
```

`fieldErrors` is `null` except on bean-validation failures (`Validation failed`), where it lists `{field, message}` entries.

### Exception to status mapping

| Exception | Status | `error` | `message` |
|---|---|---|---|
| `ShipmentNotFoundException` | 404 | `Not Found` | `Shipment not found for order: {orderId}`, `Shipment not found: {trackingNumber}` or `Shipment not found: {id}` |
| `InvalidShipmentStateException` | 400 | `Bad Request` | `Unknown shipment status` |
| `MethodArgumentNotValidException` | 400 | `Bad Request` | `Validation failed`, with `fieldErrors` |
| `HttpMessageNotReadableException` (missing or malformed body) | 400 | `Bad Request` | `Malformed request body` |
| `MethodArgumentTypeMismatchException` (for example a non-numeric `{id}`) | 400 | `Bad Request` | `Invalid value for parameter '{name}'` |
| `MissingServletRequestParameterException`, `ServletRequestBindingException` | 400 | `Bad Request` | `Missing required parameter` / `Invalid request` |
| `AuthenticationRequiredException` | 401 | `Unauthorized` | `Authentication required` |
| `AccessDeniedException` | 403 | `Forbidden` | `Access denied` |
| unmapped path (including a hostile tracking number) | 404 | `Not Found` | `Resource not found` |
| `HttpRequestMethodNotSupportedException` (for example `POST /api/v1/shipments/tracking/{n}`) | 405 | `Method Not Allowed` | `Method not allowed` |
| not acceptable | 406 | `Not Acceptable` | `Not acceptable` |
| `IllegalStatusTransitionException`, `DuplicateShipmentException` | 409 | `Conflict` | `Cannot change status from {A} to {B}`, `Cannot update status of a {DELIVERED or RETURNED} shipment`, `Shipment already exists for order: {orderId}`; `Resource already exists` for a unique-constraint race |
| `HttpMediaTypeNotSupportedException` | 415 | `Unsupported Media Type` | `Unsupported media type` |
| Anything else | 500 | `Internal Server Error` | `An unexpected error occurred`, logged at ERROR with the stack trace |

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/shipments` | `ADMIN` | `ADMIN` | Create a shipment manually. No event is published |
| GET | `/api/v1/shipments/order/{orderId}` | Bearer JWT | owner or `ADMIN` | Get the shipment of an order |
| GET | `/api/v1/shipments/tracking/{trackingNumber}` | Public, `GET` only | None | Track a shipment by tracking number (limited fields) |
| PATCH | `/api/v1/shipments/{id}/status` | `ADMIN` | `ADMIN`; transition table (409) | Change the status, append history, publish `shipment.updated` |
| GET | `/api/v1/shipments/{id}/history` | Bearer JWT | owner or `ADMIN` | Status history, oldest first |
| GET | `/hello` | Not routed (direct port only) | None | Scaffold greeting |

Shipments are normally created by the `payment.completed` consumer, not by this API.

The examples below assume `GW=http://localhost:8080` and `AUTH="Authorization: Bearer $TOKEN"`; admin-only calls use `ADMIN_AUTH` (a token for `admin` with `ADMIN_PASSWORD` from `ecommerce-platform/.env`). The api-test skill (`.claude/skills/api-test/SKILL.md`) shows how to get a token.

## POST /api/v1/shipments

Creates a shipment in `PENDING` from the request. This path differs from the automatic one (the `payment.completed` consumer) in four ways:

- it publishes **no** `shipment.created`;
- it writes no history row;
- it ignores `estimatedDelivery`;
- it does not check whether the order exists or has been paid.

There is one shipment per order (unique constraint, `V3`): a manual create for an order that already has one is `409`, and the later `payment.completed` for the order is skipped. No frontend page calls this endpoint; the `shipmentsApi.createShipment()` function exists in the frontend but is unused.

**Auth:** `ADMIN` only.

**Request body** `CreateShipmentRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `orderId` | integer (`Long`) | yes | `@NotNull` | The order must not have a shipment yet |
| `customerId` | string | yes | `@NotBlank`, `@Size(max = 255)`, no NUL | |
| `originAddress` | string | yes | `@NotBlank`, `@Size(max = 1000)`, no NUL | |
| `destinationAddress` | string | yes | `@NotBlank`, `@Size(max = 1000)`, no NUL | |
| `carrier` | string | no | `@Size(max = 50)`, no NUL | Defaults to `DHL` |
| `estimatedDelivery` | string | no | `@Size(max = 64)`, no NUL | **Ignored.** The service always sets now + 5 days |

A violation returns 400 with `fieldErrors`.

```json
{
  "orderId": 8,
  "customerId": "alice",
  "originAddress": "Warehouse, 123 Storage St",
  "destinationAddress": "Bagdat Cd. 10, Istanbul",
  "carrier": "UPS"
}
```

**Responses**

- `201 Created` with a [`ShipmentDTO`](#shipmentdto). There is no `Location` header.

  ```json
  {
    "id": 32,
    "orderId": 8,
    "customerId": "alice",
    "trackingNumber": "TRACK-9C04E1D7-5A7B33C2",
    "status": "PENDING",
    "carrier": "UPS",
    "originAddress": "Warehouse, 123 Storage St",
    "destinationAddress": "Bagdat Cd. 10, Istanbul",
    "estimatedDelivery": "2026-11-03T14:30:15.123456",
    "actualDelivery": null,
    "createdAt": "2026-10-29T14:30:15.123311"
  }
  ```

- `400` for a validation failure (`fieldErrors`) or a malformed body.
- `401` / `403` no identity / not an admin.
- `409` `Shipment already exists for order: {orderId}`.

**Side effects:** inserts one `shipments` row. Nothing is published.

**Example**

```bash
curl -s -X POST -H "$ADMIN_AUTH" -H 'Content-Type: application/json' \
  -d '{"orderId":8,"customerId":"alice","originAddress":"Warehouse, 123 Storage St","destinationAddress":"Bagdat Cd. 10, Istanbul","carrier":"UPS"}' \
  "$GW/api/v1/shipments"
```

## GET /api/v1/shipments/order/{orderId}

Returns the shipment of an order. The frontend's `OrderDetailPage` uses this endpoint.

**Auth:** Bearer JWT; the shipment's `customerId` must equal `X-Username`, or the caller is `ADMIN` (403 otherwise).

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `orderId` | path | integer (`Long`) | yes | Numeric; anything else gives 400 |

**Responses**

- `200 OK` with a [`ShipmentDTO`](#shipmentdto).
- `404` with `Shipment not found for order: {orderId}`. This is normal before the payment completes.
- `403` the shipment belongs to someone else. An order has at most one shipment.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/shipments/order/7"
```

## GET /api/v1/shipments/tracking/{trackingNumber}

Public tracking: returns a limited view for an exact, case-sensitive tracking number match. The frontend's `TrackingPage` uses this endpoint.

**Auth:** **Public**, `GET` only. The gateway requires no token on `/api/v1/shipments/tracking/*`; other methods need a token and the service answers 405. There are no service-side checks.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `trackingNumber` | path | string | yes | Format `TRACK-XXXXXXXX-XXXXXXXX` with upper-case hex digits (64 bits). Exact match |

**Responses**

- `200 OK` with a `PublicTrackingDTO`: only `trackingNumber`, `status`, `carrier`, `estimatedDelivery` and the `events` (each with `eventDescription`, `newStatus`, `location`, `eventTimestamp`). No customer, order id, ids or addresses.

  ```json
  {
    "trackingNumber": "TRACK-3F2A9C1B-4D5E6F70",
    "status": "SHIPPED",
    "carrier": "DHL",
    "estimatedDelivery": "2026-11-03T14:30:15.123456",
    "events": [
      { "eventDescription": "Left the warehouse", "newStatus": "SHIPPED", "location": "Istanbul hub", "eventTimestamp": "2026-10-30T09:12:44.512031" }
    ]
  }
  ```

- `404` with `Shipment not found: {trackingNumber}`.

**Side effects:** none.

**Example** (no token)

```bash
curl -s "$GW/api/v1/shipments/tracking/TRACK-3F2A9C1B-4D5E6F70"
```

## PATCH /api/v1/shipments/{id}/status

Sets a shipment's status. This endpoint is the only way a status ever changes: there is no scheduler. No frontend page calls it either; the `useUpdateShipmentStatus()` hook exists but is unused.

The service handles a request in this order:

1. Load the shipment, or return `404`.
2. Convert `status` with `ShipmentStatus.valueOf()`. The conversion is case-sensitive, and an unknown value returns `400`.
3. Refuse with `409` unless the move is in the transition table: `PENDING` to `PROCESSING`, `PROCESSING` to `SHIPPED`, `SHIPPED` to `OUT_FOR_DELIVERY` or `RETURNED`, `OUT_FOR_DELIVERY` to `DELIVERED` or `RETURNED`. `DELIVERED` and `RETURNED` are terminal.
4. Apply the change.

Setting `DELIVERED` also sets `actualDelivery` to now.

**Auth:** `ADMIN` only (403 at the gateway and in the service).

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric |

**Request body** `UpdateShipmentStatusRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `status` | string | yes | `@NotBlank`, `@Size(max = 30)`, no NUL | Must be an exact `ShipmentStatus` name. Blank or missing gives 400, and an unknown value gives 400 |
| `location` | string | no | `@Size(max = 255)`, no NUL | Stored in the history and sent in `shipment.updated` |
| `description` | string | no | `@Size(max = 500)`, no NUL | History text. Defaults to `Status updated to {STATUS}` |

```json
{ "status": "SHIPPED", "location": "Istanbul hub", "description": "Left the warehouse" }
```

**Responses**

- `200 OK` with the updated [`ShipmentDTO`](#shipmentdto).
- `400` for a validation failure, an unknown `status` or a malformed body.
- `401` / `403` no identity / not an admin.
- `404` with `Shipment not found: {id}`.
- `409` with `Cannot change status from {A} to {B}` or `Cannot update status of a DELIVERED shipment` (or `RETURNED`); nothing is published.

**Side effects:**

- Updates the `shipments` row (`status`, `updated_at`, and `actual_delivery` for `DELIVERED`).
- Inserts a `shipment_events` row.
- Publishes `shipment.updated` (key `orderId`) before commit. notification-service consumes it.

**Example**

```bash
curl -s -X PATCH -H "$ADMIN_AUTH" -H 'Content-Type: application/json' \
  -d '{"status":"SHIPPED","location":"Istanbul hub","description":"Left the warehouse"}' \
  "$GW/api/v1/shipments/31/status"
```

## GET /api/v1/shipments/{id}/history

Returns the shipment's status changes in ascending `eventTimestamp` order. Creating a shipment records nothing, so a shipment that has never been PATCHed has an empty history.

**Auth:** Bearer JWT; owner of the shipment or `ADMIN` (403 otherwise). The frontend's public `TrackingPage` no longer calls it: the public tracking response carries the events inline.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric |

**Responses**

- `200 OK` with a JSON array of [`ShipmentEventDTO`](#shipmenteventdto). The array may be empty.

  ```json
  [
    {
      "id": 90,
      "shipmentId": 31,
      "eventDescription": "Left the warehouse",
      "newStatus": "SHIPPED",
      "location": "Istanbul hub",
      "eventTimestamp": "2026-10-30T09:12:44.512031"
    }
  ]
  ```

- `403` the shipment belongs to someone else.
- `404` with `Shipment not found: {id}`.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/shipments/31/history"
```

## GET /hello

This greeting is left over from project scaffolding (`controller/ShippingController.java`, `service/ShippingService.java`). The gateway has no route for it, so it is reachable only on the direct port.

**Responses:** `200 OK`, `text/plain`, body `Hello from Shipping Service!`.

```bash
curl -s http://localhost:8086/hello
```

## Schemas

### `ShipmentDTO`

Source: `dto/ShipmentDTO.java`.

| Field | Type | Notes |
|---|---|---|
| `id` | integer (`Long`) | Sequential |
| `orderId` | integer (`Long`) | |
| `customerId` | string | From `payment.completed` (in practice the username) or from the REST body |
| `trackingNumber` | string | `TRACK-XXXXXXXX-XXXXXXXX` |
| `status` | string | `ShipmentStatus` name |
| `carrier` | string | `DHL` unless the REST request set another value |
| `originAddress` | string | `Warehouse, 123 Storage St` for automatically created shipments |
| `destinationAddress` | string | `Customer Address` (a placeholder) for automatically created shipments |
| `estimatedDelivery` | string (ISO-8601 local date-time) | Creation time plus 5 days |
| `actualDelivery` | string or null | Set when the status becomes `DELIVERED` |
| `createdAt` | string (ISO-8601 local date-time) | |

`updatedAt` exists in the database but is not part of the DTO.

### `ShipmentEventDTO`

Source: `dto/ShipmentEventDTO.java`.

| Field | Type | Notes |
|---|---|---|
| `id` | integer (`Long`) | |
| `shipmentId` | integer (`Long`) | |
| `eventDescription` | string | The request's `description` or `Status updated to {STATUS}` |
| `newStatus` | string or null | `ShipmentStatus` name. Always set by the current code |
| `location` | string or null | |
| `eventTimestamp` | string (ISO-8601 local date-time) | |

### `CreateShipmentRequest`

See [POST /api/v1/shipments](#post-apiv1shipments). Source: `dto/CreateShipmentRequest.java`.

### `UpdateShipmentStatusRequest`

See [PATCH /api/v1/shipments/{id}/status](#patch-apiv1shipmentsidstatus). Source: `dto/UpdateShipmentStatusRequest.java`.

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
| `fieldErrors` | null | Never filled by this service |
