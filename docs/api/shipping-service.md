# Shipping service API reference

Call the API through the gateway at `http://localhost:8080`. The service also listens directly on `http://localhost:8086`, which bypasses the gateway and its JWT check; use that for development only.

- **Try it:** the platform Swagger UI at `http://localhost:8080/swagger-ui.html`, entry `shipping-service`. Calls go through the gateway, so click **Authorize** with a token from `POST /api/v1/users/login` first (only tracking is public).
- **OpenAPI document:** `http://localhost:8080/api-docs/shipping-service` (through the gateway), `http://localhost:8086/api-docs` (direct), or the committed snapshot [openapi/shipping-service.json](openapi/shipping-service.json).

Service overview: [shipping-service](../services/shipping-service.md).

## Conventions

- **Content type:** request and response bodies are `application/json`. The only exception is `GET /hello`, which returns `text/plain`.
- **Authentication:**
  - `/api/v1/shipments/tracking/` and everything under it is public at the gateway for every HTTP method. The service maps only `GET` there.
  - Every other path needs `Authorization: Bearer <JWT>`. Without a valid token the gateway answers 401 with an empty body.
  - The service itself reads no `X-User-*` header and applies no role or ownership rule.
- **Correlation:** every response carries `X-Correlation-Id`. The service reuses the incoming value or generates a UUID.
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

`fieldErrors` is always `null` in this service. It has no handler for `MethodArgumentNotValidException`, so bean-validation failures come back as 500, as the table below shows.

### Exception to status mapping

| Exception | Status | `error` | `message` |
|---|---|---|---|
| `ShipmentNotFoundException` | 404 | `Not Found` | `Shipment not found for order: {orderId}`, `Shipment not found: {trackingNumber}` or `Shipment not found: {id}` |
| `InvalidShipmentStateException` | 400 | `Bad Request` | `Shipment already exists for order: {orderId}` or `Cannot update status of a {DELIVERED or RETURNED} shipment` |
| `HttpMessageNotReadableException` (missing or malformed body), `MethodArgumentTypeMismatchException` (for example a non-numeric `{id}`), `MissingServletRequestParameterException`, `ServletRequestBindingException` | 400 | `Bad Request` | The exception's own message |
| `HttpRequestMethodNotSupportedException` (for example `POST /api/v1/shipments/tracking/{n}`) | 405 | `Method Not Allowed` | The exception's own message |
| Anything else: **`MethodArgumentNotValidException` (missing or blank required field)**, `IllegalArgumentException` from an unknown status value, database errors (column length overflow, two shipments for one order), `NoResourceFoundException` (unknown path), `HttpMediaTypeNotSupportedException` | 500 | `Internal Server Error` | `An unexpected error occurred`, logged at ERROR with the stack trace |

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/shipments` | Bearer JWT | None | Create a shipment manually. No event is published |
| GET | `/api/v1/shipments/order/{orderId}` | Bearer JWT | None | Get the shipment of an order |
| GET | `/api/v1/shipments/tracking/{trackingNumber}` | Public, any method | None | Track a shipment by tracking number |
| PATCH | `/api/v1/shipments/{id}/status` | Bearer JWT | None | Change the status, append history, publish `shipment.updated` |
| GET | `/api/v1/shipments/{id}/history` | Bearer JWT | None | Status history, oldest first |
| GET | `/hello` | Not routed (direct port only) | None | Scaffold greeting |

Shipments are normally created by the `payment.completed` consumer, not by this API.

The examples below assume `GW=http://localhost:8080` and `AUTH="Authorization: Bearer $TOKEN"`. The api-test skill (`.claude/skills/api-test/SKILL.md`) shows how to get a token.

## POST /api/v1/shipments

Creates a shipment in `PENDING` from the request. This path differs from the automatic one (the `payment.completed` consumer) in four ways:

- it publishes **no** `shipment.created`;
- it writes no history row;
- it ignores `estimatedDelivery`;
- it does not check whether the order exists or has been paid.

If it runs first, the later `payment.completed` for the order is skipped. No frontend page calls this endpoint; the `shipmentsApi.createShipment()` function exists in the frontend but is unused.

**Auth:** Bearer JWT. No service-side checks.

**Request body** `CreateShipmentRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `orderId` | integer (`Long`) | yes | `@NotNull` | The order must not have a shipment yet |
| `customerId` | string | yes | `@NotBlank` | Stored as-is. At most 255 characters in the database |
| `originAddress` | string | yes | `@NotBlank` | |
| `destinationAddress` | string | yes | `@NotBlank` | |
| `carrier` | string | no | none | Defaults to `DHL`. Free text, at most 50 characters in the database |
| `estimatedDelivery` | string | no | none | **Ignored.** The service always sets now + 5 days |

A violation of `@NotNull` or `@NotBlank` returns **500**, not 400 (see [Conventions](#exception-to-status-mapping)).

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
    "trackingNumber": "TRACK-9C04E1D7-B",
    "status": "PENDING",
    "carrier": "UPS",
    "originAddress": "Warehouse, 123 Storage St",
    "destinationAddress": "Bagdat Cd. 10, Istanbul",
    "estimatedDelivery": "2026-11-03T14:30:15.123456",
    "actualDelivery": null,
    "createdAt": "2026-10-29T14:30:15.123311"
  }
  ```

- `400` with `Shipment already exists for order: {orderId}`, or when the body is malformed.
- `500` when a required field is missing or blank, a value overflows a column, or a tracking number collides.

**Side effects:** inserts one `shipments` row. Nothing is published.

**Example**

```bash
curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"orderId":8,"customerId":"alice","originAddress":"Warehouse, 123 Storage St","destinationAddress":"Bagdat Cd. 10, Istanbul","carrier":"UPS"}' \
  "$GW/api/v1/shipments"
```

## GET /api/v1/shipments/order/{orderId}

Returns the shipment of an order. The frontend's `OrderDetailPage` uses this endpoint.

**Auth:** Bearer JWT. No service-side checks.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `orderId` | path | integer (`Long`) | yes | Numeric; anything else gives 400 |

**Responses**

- `200 OK` with a [`ShipmentDTO`](#shipmentdto).
- `404` with `Shipment not found for order: {orderId}`. This is normal before the payment completes.
- `500` when the order has two shipments, which the schema does not prevent.

**Side effects:** none.

**Example**

```bash
curl -s -H "$AUTH" "$GW/api/v1/shipments/order/7"
```

## GET /api/v1/shipments/tracking/{trackingNumber}

Public tracking: returns the whole shipment for an exact, case-sensitive tracking number match. The frontend's `TrackingPage` uses this endpoint.

**Auth:** **Public.** The gateway requires no token on `/api/v1/shipments/tracking/` and everything under it, for any method. Here the service answers only `GET`; other methods get 405. There are no service-side checks.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `trackingNumber` | path | string | yes | Format `TRACK-XXXXXXXX-X` with upper-case hex digits. Exact match |

**Responses**

- `200 OK` with a [`ShipmentDTO`](#shipmentdto). The response exposes these fields to anyone holding the number:
  - `id`, `orderId` and `customerId`, which in practice is the customer's username;
  - both addresses;
  - `carrier`, `status` and the dates.

  ```json
  {
    "id": 31,
    "orderId": 7,
    "customerId": "alice",
    "trackingNumber": "TRACK-3F2A9C1B-4",
    "status": "SHIPPED",
    "carrier": "DHL",
    "originAddress": "Warehouse, 123 Storage St",
    "destinationAddress": "Customer Address",
    "estimatedDelivery": "2026-11-03T14:30:15.123456",
    "actualDelivery": null,
    "createdAt": "2026-10-29T14:30:15.122870"
  }
  ```

- `404` with `Shipment not found: {trackingNumber}`.

**Side effects:** none.

**Example** (no token)

```bash
curl -s "$GW/api/v1/shipments/tracking/TRACK-3F2A9C1B-4"
```

## PATCH /api/v1/shipments/{id}/status

Sets a shipment's status. This endpoint is the only way a status ever changes: there is no scheduler. No frontend page calls it either; the `useUpdateShipmentStatus()` hook exists but is unused.

The service handles a request in this order:

1. Load the shipment, or return `404`.
2. Convert `status` with `ShipmentStatus.valueOf()`. The conversion is case-sensitive, and an unknown value returns `500`.
3. Refuse with `400` if the current status is `DELIVERED` or `RETURNED`.
4. Apply the change.

Any status may be set from any non-terminal status, including the current one or an earlier one. Setting `DELIVERED` also sets `actualDelivery` to now.

**Auth:** Bearer JWT. No service-side checks: any logged-in user can change any shipment.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (`Long`) | yes | Numeric |

**Request body** `UpdateShipmentStatusRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `status` | string | yes | `@NotBlank` | Must be an exact `ShipmentStatus` name. Blank or missing gives 500, and an unknown value gives 500 |
| `location` | string | no | none | Stored in the history and sent in `shipment.updated`. At most 255 characters in the database |
| `description` | string | no | none | History text. Defaults to `Status updated to {STATUS}`. At most 500 characters in the database |

```json
{ "status": "SHIPPED", "location": "Istanbul hub", "description": "Left the warehouse" }
```

**Responses**

- `200 OK` with the updated [`ShipmentDTO`](#shipmentdto).
- `400` with `Cannot update status of a DELIVERED shipment` (or `RETURNED`), or when the body is malformed.
- `404` with `Shipment not found: {id}`.
- `500` when `status` is missing or blank, `status` is not an enum name, or `location` or `description` exceeds the column length. In the last case the commit fails after `shipment.updated` has already been sent.

**Side effects:**

- Updates the `shipments` row (`status`, `updated_at`, and `actual_delivery` for `DELIVERED`).
- Inserts a `shipment_events` row.
- Publishes `shipment.updated` (key `orderId`) before commit. notification-service consumes it.

**Example**

```bash
curl -s -X PATCH -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"status":"SHIPPED","location":"Istanbul hub","description":"Left the warehouse"}' \
  "$GW/api/v1/shipments/31/status"
```

## GET /api/v1/shipments/{id}/history

Returns the shipment's status changes in ascending `eventTimestamp` order. Creating a shipment records nothing, so a shipment that has never been PATCHed has an empty history.

**Auth:** Bearer JWT. No service-side checks. The frontend's public `TrackingPage` calls this endpoint too. An anonymous visitor therefore gets 401 there, and the frontend redirects to `/login`.

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
| `trackingNumber` | string | `TRACK-XXXXXXXX-X` |
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
