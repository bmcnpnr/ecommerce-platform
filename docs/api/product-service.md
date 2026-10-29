# Product Service API reference

Base URL through the gateway `http://localhost:8080`; direct (bypasses the gateway, dev only) `http://localhost:8082`. Live OpenAPI from springdoc: `http://localhost:8082/api-docs`, Swagger UI `http://localhost:8082/swagger-ui.html`.

Service overview: [product-service](../services/product-service.md).

## Conventions

**Content type.** Request bodies are `application/json`. Every response except `204` is `application/json`.

**Authentication.** Enforced only by the gateway. `GET` requests under `/api/v1/products` and `/api/v1/categories` are public. `POST`, `PUT`, `PATCH` and `DELETE` need `Authorization: Bearer <JWT>`; without a valid token the gateway answers `401` with an empty body. The gateway answers `403` unless the token's role is exactly `ADMIN`, and the service checks again (`@AdminOnly`: `401` without identity, `403` for any other role). Requests sent directly to port 8082 skip the gateway, so they need the `X-Username` and `X-User-Role` headers. `/internal/**` is service-to-service only and not routed. An admin token can be obtained like this (`ADMIN_PASSWORD` comes from `ecommerce-platform/.env`):

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/users/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
```

**Error body.** Every error produced by the service has this shape (`exception/ErrorResponse.java`):

```json
{
  "timestamp": "2026-10-29T18:07:12.345678",
  "status": 404,
  "error": "Not Found",
  "message": "Product not found with id: 999",
  "path": "/api/v1/products/999",
  "correlationId": "5f0c0a8e-0d43-4d44-9a3a-1f0e5b2c7d11",
  "fieldErrors": null
}
```

`fieldErrors` is `null` except on bean-validation failures, where it is a list of `{"field": "...", "message": "..."}` in no particular order:

```json
{
  "timestamp": "2026-10-29T18:07:12.345678",
  "status": 400,
  "error": "Bad Request",
  "message": "Validation failed",
  "path": "/api/v1/products",
  "correlationId": "5f0c0a8e-0d43-4d44-9a3a-1f0e5b2c7d11",
  "fieldErrors": [
    { "field": "sku", "message": "SKU is required" },
    { "field": "price", "message": "Price must be greater than 0" }
  ]
}
```

**Exception to status mapping** (`exception/GlobalExceptionHandler.java`):

| Exception | Status | `error` | `message` |
|---|---|---|---|
| `ProductNotFoundException` | 404 | `Not Found` | `Product not found with id: <id>` or `Product not found with SKU: <sku>` |
| `CategoryNotFoundException` | 404 | `Not Found` | `Category not found: <id>` |
| `ProductAlreadyExistsException` | 409 | `Conflict` | `Product with SKU already exists: <sku>` or `Category already exists: <name>` |
| `InsufficientStockException` | 400 | `Bad Request` | `Insufficient stock for product <sku>. Available: <n>, Requested: <m>` |
| `MethodArgumentNotValidException` (a `@Valid` body failed) | 400 | `Bad Request` | `Validation failed`, plus `fieldErrors` |
| `HttpMessageNotReadableException` (missing or malformed body, wrong JSON type, unknown enum value, fractional integer) | 400 | `Bad Request` | `Malformed request body` |
| `MissingServletRequestParameterException`, `ServletRequestBindingException` | 400 | `Bad Request` | `Missing required parameter '<name>'` |
| `MethodArgumentTypeMismatchException` (e.g. a non-numeric id) | 400 | `Bad Request` | `Invalid value for parameter '<name>'` |
| invalid request (page size over 100, NUL byte, unknown sort property) | 400 | `Bad Request` | e.g. `Page size must be between 1 and 100`, `Invalid sort property` |
| missing identity on an admin endpoint | 401 | `Unauthorized` | `Authentication required` |
| not `ADMIN` | 403 | `Forbidden` | `Access denied` |
| unmapped path | 404 | `Not Found` | `Resource not found` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | `Method not allowed` |
| unacceptable `Accept` | 406 | `Not Acceptable` | `Not acceptable` |
| unique-constraint race | 409 | `Conflict` | `Resource already exists` |
| unsupported `Content-Type` | 415 | `Unsupported Media Type` | `Unsupported media type` |
| anything else | 500 | `Internal Server Error` | `An unexpected error occurred` (logged at ERROR with the stack trace) |

"Anything else" is any unexpected failure, e.g. a non-unique database constraint violation.

Every response carries `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.

**Pagination.** `GET /api/v1/products` and `GET /api/v1/products/search` take Spring Data's pageable parameters:

| Parameter | Default | Notes |
|---|---|---|
| `page` | `0` | Zero-based. Negative or non-numeric values fall back to 0. |
| `size` | `20` (`@PageableDefault`) | Values below 1 fall back to 20; values above 100 are `400` `Page size must be between 1 and 100`. |
| `sort` | unsorted | `property` or `property,asc` / `property,desc`; repeat the parameter for several keys. Properties are the entity's: `id`, `sku`, `name`, `description`, `price`, `stockQuantity`, `brand`, `categoryId`, `status`, `createdAt`, `updatedAt`. An unknown property returns 400. |

The response is a Spring Data `Page` serialized directly (`spring.data.web.pageable.serialization-mode` is left at `direct`):

```json
{
  "content": [ { "id": 1, "sku": "SKU-001", "name": "Wireless Mouse", "...": "..." } ],
  "empty": false,
  "first": true,
  "last": true,
  "number": 0,
  "numberOfElements": 1,
  "pageable": {
    "offset": 0,
    "pageNumber": 0,
    "pageSize": 20,
    "paged": true,
    "sort": { "empty": true, "sorted": false, "unsorted": true },
    "unpaged": false
  },
  "size": 20,
  "sort": { "empty": true, "sorted": false, "unsorted": true },
  "totalElements": 1,
  "totalPages": 1
}
```

The frontend reads `content`, `totalElements`, `totalPages`, `size`, `number`, `first` and `last`. Spring Data logs a one-time warning that this direct shape is not a guaranteed-stable contract.

**Dates.** `LocalDateTime` values are ISO-8601 strings without an offset, in the server JVM's local time, e.g. `2026-10-29T18:07:12.345678` (Jackson 3 default; no `spring.jackson.*` settings).

**Numbers.** `price` is a JSON number. Values read from the database carry four decimals because the column is `NUMERIC(19,4)` (`49.9900`); the `201` response of `POST /api/v1/products` echoes the scale the client sent (`49.99`). PostgreSQL rounds a price with more than four decimals when storing it, so later reads can differ from the `201` body. A fractional number sent for an integer field (`stockQuantity`, `delta`) is truncated toward zero (Jackson's `ACCEPT_FLOAT_AS_INT` is on), e.g. `-1.9` becomes `-1`.

**Other JSON rules.** Unknown request properties are ignored (Jackson 3 default). `null` fields are written as `null`, not omitted. Key order in the examples follows the DTO declarations; clients must not depend on it.

**Correlation.** Send `X-Correlation-Id` (`^[A-Za-z0-9._-]{1,64}$`) to have it logged and echoed back; otherwise the service generates a UUID and returns it in the same header. It also appears in error bodies as `correlationId`.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/products` | `ADMIN` | `ADMIN` | Create a product |
| GET | `/api/v1/products` | Public | none | Page of `ACTIVE` products |
| GET | `/api/v1/products/{id}` | Public | none | Product by id, any status |
| GET | `/api/v1/products/sku/{sku}` | Public | none | Product by SKU, any status |
| GET | `/api/v1/products/search` | Public | none | Page of `ACTIVE` products whose name contains `q` |
| GET | `/api/v1/products/category/{categoryId}` | Public | none | `ACTIVE` products of one category |
| PUT | `/api/v1/products/{id}` | `ADMIN` | `ADMIN` | Partial update |
| PATCH | `/api/v1/products/{id}/stock` | `ADMIN` | `ADMIN` | Add or remove stock |
| PATCH | `/internal/v1/products/{id}/stock` | not routed | none | Same, for order-service |
| DELETE | `/api/v1/products/{id}` | `ADMIN` | `ADMIN` | Soft delete |
| POST | `/api/v1/categories` | `ADMIN` | `ADMIN` | Create a category |
| GET | `/api/v1/categories` | Public | none | All categories |
| GET | `/api/v1/categories/{id}` | Public | none | Category by id |

## POST /api/v1/products

Creates a product with status `ACTIVE`.

**Auth:** `ADMIN` (403 at the gateway and in the service for any other role).

**Request body** `CreateProductRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `sku` | string | yes | `@NotBlank` "SKU is required"; `@Size(max = 100)` "size must be between 0 and 100" | Must not exist yet (409). Case-sensitive. Cannot be changed later. |
| `name` | string | yes | `@NotBlank` "Name is required"; `@Size(max = 200)` "size must be between 0 and 200" | |
| `description` | string | no | — | Unlimited (`TEXT`). |
| `price` | number | yes | `@NotNull` "Price is required"; `@DecimalMin("0", exclusive)` "Price must be greater than 0"; `@Digits(15, 2)` "Price must have at most 15 integer digits and 2 decimals" | More digits are `400`, not rounded. |
| `stockQuantity` | integer | yes | `@NotNull` "Stock quantity is required"; `@Min(0)` "Stock quantity cannot be negative" | The product is `ACTIVE` even when this is 0. |
| `brand` | string | no | `@Size(max = 100)` "size must be between 0 and 100" | |
| `categoryId` | integer | no | Must reference an existing category (404 otherwise). | |

```json
{
  "sku": "SKU-001",
  "name": "Wireless Mouse",
  "description": "Ergonomic wireless mouse",
  "price": 49.99,
  "stockQuantity": 50,
  "brand": "Logi",
  "categoryId": 10
}
```

**Responses**

- `201 Created` with [`ProductDTO`](#productdto). `status` is `ACTIVE`, `updatedAt` is `null`, `price` has the scale that was sent.

  ```json
  {
    "id": 1,
    "sku": "SKU-001",
    "name": "Wireless Mouse",
    "description": "Ergonomic wireless mouse",
    "price": 49.99,
    "stockQuantity": 50,
    "brand": "Logi",
    "categoryId": 10,
    "status": "ACTIVE",
    "createdAt": "2026-10-29T18:07:12.345678",
    "updatedAt": null
  }
  ```
- `400` validation failure (`fieldErrors` set) or malformed JSON.
- `404` `Category not found: <categoryId>`.
- `409` `Product with SKU already exists: <sku>`.
- `401` / `403` not an admin.
- `409` `Resource already exists` when two requests create the same SKU at the same time.

**Side effects:** one `INSERT` into `products`; log line `Product created: SKU=<sku>`. No events.

**Example**

```bash
curl -s -X POST http://localhost:8080/api/v1/products \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"sku":"SKU-001","name":"Wireless Mouse","price":49.99,"stockQuantity":50,"brand":"Logi","categoryId":10}'
```

## GET /api/v1/products

Returns a page of products whose status is `ACTIVE`. `OUT_OF_STOCK` and `INACTIVE` products are never included.

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `page` | query | integer | no | `0` | See [Pagination](#conventions). |
| `size` | query | integer | no | `20` | 1 to 100. |
| `sort` | query | string | no | unsorted | `property`, `property,asc` or `property,desc`; repeatable. |

**Responses**

- `200 OK` with a [`Page`](#page) of [`ProductDTO`](#productdto).
- `400` for an unknown `sort` property or a `size` over 100.

**Side effects:** none.

**Example**

```bash
curl -s 'http://localhost:8080/api/v1/products?page=0&size=20&sort=price,desc'
```

## GET /api/v1/products/{id}

Returns one product, whatever its status (soft-deleted `INACTIVE` and `OUT_OF_STOCK` products are returned too). order-, catalog- and review-service call this endpoint over Feign.

**Auth:** Public.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | Numeric; otherwise 400. |

**Responses**

- `200 OK` with [`ProductDTO`](#productdto). `price` has four decimals.

  ```json
  {
    "id": 1,
    "sku": "SKU-001",
    "name": "Wireless Mouse",
    "description": "Ergonomic wireless mouse",
    "price": 49.9900,
    "stockQuantity": 48,
    "brand": "Logi",
    "categoryId": 10,
    "status": "ACTIVE",
    "createdAt": "2026-10-29T18:07:12.345678",
    "updatedAt": "2026-10-29T18:15:40.102233"
  }
  ```
- `400` non-numeric `id`.
- `404` `Product not found with id: <id>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/products/1
```

## GET /api/v1/products/sku/{sku}

Returns the product with this exact SKU (case-sensitive), whatever its status.

**Auth:** Public.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `sku` | path | string | yes | — | Exact match. |

**Responses**

- `200 OK` with [`ProductDTO`](#productdto).
- `404` `Product not found with SKU: <sku>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/products/sku/SKU-001
```

## GET /api/v1/products/search

Returns a page of `ACTIVE` products whose `name` contains `q`, ignoring case. Only the name is searched (not SKU, brand or description). The query is `upper(name) like upper('%<q>%')`; Spring Data escapes `%` and `_` in `q`, so they match literally. An empty `q` matches every `ACTIVE` product.

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `q` | query | string | yes | — | Missing: 400. |
| `page` | query | integer | no | `0` | |
| `size` | query | integer | no | `20` | 1 to 100. |
| `sort` | query | string | no | unsorted | `property`, `property,asc` or `property,desc`; repeatable. |

**Responses**

- `200 OK` with a [`Page`](#page) of [`ProductDTO`](#productdto).
- `400` `q` missing.
- `400` for an unknown `sort` property or a `size` over 100.

**Side effects:** none.

**Example**

```bash
curl -s 'http://localhost:8080/api/v1/products/search?q=mouse&size=10'
```

## GET /api/v1/products/category/{categoryId}

Returns the `ACTIVE` products whose `categoryId` equals the given id, as a plain list (not paged, no defined order). Products in child categories are not included.

**Auth:** Public.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `categoryId` | path | integer (int64) | yes | — | The category must exist. |

**Responses**

- `200 OK` with an array of [`ProductDTO`](#productdto) (possibly empty).
- `404` `Category not found: <categoryId>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/products/category/10
```

## PUT /api/v1/products/{id}

Partially updates a product: every non-null field in the body replaces the stored value, every `null` or absent field is left unchanged, so a field cannot be cleared. SKU and stock cannot be changed here; if the body contains `sku` or `stockQuantity` they are silently ignored (use the stock endpoint for stock).

**Auth:** `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Request body** `UpdateProductRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `name` | string | no | `@Size(max = 200)` | An empty string is accepted. |
| `description` | string | no | — | |
| `price` | number | no | `@DecimalMin("0.01")` "Price must be greater than 0" | |
| `brand` | string | no | `@Size(max = 100)` | |
| `categoryId` | integer | no | Checked by the service; an unknown id is `404`. | |
| `status` | string | no | Must be exactly `ACTIVE`, `INACTIVE` or `OUT_OF_STOCK`; anything else returns 400 `Unknown product status: <value>`. | Not checked against the stock; `ACTIVE` reactivates a soft-deleted product. |

```json
{
  "name": "Wireless Mouse M2",
  "price": 44.50,
  "status": "ACTIVE"
}
```

**Responses**

- `200 OK` with the updated [`ProductDTO`](#productdto); `updatedAt` is set.
- `400` validation failure or malformed JSON.
- `404` `Product not found with id: <id>`.
- `400` unknown `status` value.
- `404` `Category not found: <categoryId>`.

**Side effects:** one `UPDATE products` that writes every column (no optimistic lock, see the service document); no events. The new price is what order-service copies into order items from then on.

**Example**

```bash
curl -s -X PUT http://localhost:8080/api/v1/products/1 \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"price":44.50}'
```

## PATCH /api/v1/products/{id}/stock

Adds `delta` to the product's stock. A positive delta adds stock (restock, order cancellation); a negative delta removes it (order reservation); `0` is allowed. order-service calls this with `-quantity` when an item is added to an order and with `+quantity` per item when an order is cancelled.

**Auth:** `ADMIN`. order-service calls the same operation on `PATCH /internal/v1/products/{id}/stock` (same body and response, no identity needed), which the gateway never routes.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Request body** `StockUpdateRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `delta` | integer | yes | `@NotNull` "Delta is required" | Any integer; a fractional number is `400`. |

```json
{ "delta": -2 }
```

**Behaviour** (`ProductService.updateStock()`):

1. Load the product (404 if it does not exist). The status is not checked, so `INACTIVE` products can be adjusted too.
2. `new = stockQuantity + delta`. If `new < 0`, answer 400 and write nothing.
3. If `new == 0`, set status `OUT_OF_STOCK` (from any status, including `INACTIVE`). If `new > 0` and the status was `OUT_OF_STOCK`, set `ACTIVE`. Otherwise keep the status.
4. Set `stockQuantity = new` and `updatedAt = now`, save, return the product.

**Concurrency:** none. The product is read without a lock and written back whole at commit, there is no version column and no atomic `stock_quantity = stock_quantity + delta` update, so two concurrent requests for the same product can both succeed and the later commit overwrites the earlier one (lost update). The stored stock never goes negative, but reservations can oversell and restorations can be lost. The request is not idempotent: repeating it applies the delta again.

**Responses**

- `200 OK` with the updated [`ProductDTO`](#productdto).

  ```json
  {
    "id": 1,
    "sku": "SKU-001",
    "name": "Wireless Mouse",
    "description": "Ergonomic wireless mouse",
    "price": 49.9900,
    "stockQuantity": 48,
    "brand": "Logi",
    "categoryId": 10,
    "status": "ACTIVE",
    "createdAt": "2026-10-29T18:07:12.345678",
    "updatedAt": "2026-10-29T18:15:40.102233"
  }
  ```
- `400` insufficient stock:

  ```json
  {
    "timestamp": "2026-10-29T18:16:02.554310",
    "status": 400,
    "error": "Bad Request",
    "message": "Insufficient stock for product SKU-001. Available: 50, Requested: 1000",
    "path": "/api/v1/products/1/stock",
    "correlationId": "0b6f2a4e-7f0e-4f3c-a2a8-6c2c7f0e9d41",
    "fieldErrors": null
  }
  ```
- `400` `delta` missing or `null` (`Validation failed`, `fieldErrors: [{"field": "delta", "message": "Delta is required"}]`), malformed JSON or a non-numeric `delta`, or a non-numeric `id`.
- `404` `Product not found with id: <id>`.
- `405` for any method other than `PATCH` on this path.

**Side effects:** one `UPDATE products` (every column); log line `Stock updated for product <sku>: <old> -> <new>`. No events, so catalog-service's `stockStatus` is not updated.

**Example**

```bash
curl -s -X PATCH http://localhost:8080/api/v1/products/1/stock \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"delta": -2}'
```

## DELETE /api/v1/products/{id}

Soft-deletes a product: its status becomes `INACTIVE`. The row stays; the product disappears from the list, search and category endpoints but is still returned by id and SKU to an `ADMIN`; other callers get `404`. Deleting an already `INACTIVE` product succeeds again.

**Auth:** `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Responses**

- `204 No Content`, no body.
- `404` `Product not found with id: <id>`.

**Side effects:** one `UPDATE products` setting `status = 'INACTIVE'` and `updated_at`; log line `Product soft-deleted: <sku>`. Catalog entries for the product are not touched.

**Example**

```bash
curl -s -X DELETE http://localhost:8080/api/v1/products/1 -H "Authorization: Bearer $TOKEN"
```

## POST /api/v1/categories

Creates a category, optionally under a parent.

**Auth:** `ADMIN`.

**Request body** `CreateCategoryRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `name` | string | yes | `@NotBlank` "Category name is required"; `@Size(max = 100)` "size must be between 0 and 100" | Unique (409), case-sensitive. |
| `description` | string | no | — | |
| `parentCategoryId` | integer | no | An unknown id is `404`. | |

```json
{ "name": "Accessories", "description": "Mice, keyboards, cables", "parentCategoryId": 10 }
```

**Responses**

- `201 Created` with [`CategoryDTO`](#categorydto).

  ```json
  {
    "id": 11,
    "name": "Accessories",
    "description": "Mice, keyboards, cables",
    "parentCategoryId": 10,
    "createdAt": "2026-10-29T18:20:01.004512"
  }
  ```
- `400` validation failure or malformed JSON.
- `409` `Category already exists: <name>` (also for a concurrent create with the same name).
- `404` `Category not found: <parentCategoryId>`.

**Side effects:** one `INSERT` into `categories`. No events.

**Example**

```bash
curl -s -X POST http://localhost:8080/api/v1/categories \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Accessories","parentCategoryId":10}'
```

## GET /api/v1/categories

Returns every category as a flat list (not paged, no defined order). Hierarchy is expressed only by `parentCategoryId`. catalog-service calls this on every sync to resolve a category name.

**Auth:** Public.

**Responses**

- `200 OK` with an array of [`CategoryDTO`](#categorydto).

  ```json
  [
    { "id": 10, "name": "Electronics", "description": "Devices and accessories", "parentCategoryId": null, "createdAt": "2026-10-29T18:00:00.000001" },
    { "id": 11, "name": "Accessories", "description": "Mice, keyboards, cables", "parentCategoryId": 10, "createdAt": "2026-10-29T18:20:01.004512" }
  ]
  ```

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/categories
```

## GET /api/v1/categories/{id}

Returns one category.

**Auth:** Public.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Responses**

- `200 OK` with [`CategoryDTO`](#categorydto).
- `404` `Category not found: <id>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/categories/10
```

## Schemas

### ProductDTO

`dto/ProductDTO.java`. Returned by every product endpoint.

| Field | JSON type | Java type | Nullable | Notes |
|---|---|---|---|---|
| `id` | integer | `Long` | no | |
| `sku` | string | `String` | no | |
| `name` | string | `String` | no | |
| `description` | string | `String` | yes | |
| `price` | number | `BigDecimal` | no | Four decimals when read from the database. |
| `stockQuantity` | integer | `Integer` | no | |
| `brand` | string | `String` | yes | |
| `categoryId` | integer | `Long` | yes | |
| `status` | string | `String` | no | `ACTIVE`, `INACTIVE` or `OUT_OF_STOCK`. |
| `createdAt` | string (date-time) | `LocalDateTime` | no | |
| `updatedAt` | string (date-time) | `LocalDateTime` | yes | `null` until the first update. |

### CategoryDTO

`dto/CategoryDTO.java`.

| Field | JSON type | Java type | Nullable | Notes |
|---|---|---|---|---|
| `id` | integer | `Long` | no | |
| `name` | string | `String` | no | |
| `description` | string | `String` | yes | |
| `parentCategoryId` | integer | `Long` | yes | |
| `createdAt` | string (date-time) | `LocalDateTime` | no | |

### CreateProductRequest

`dto/CreateProductRequest.java`. See [POST /api/v1/products](#post-apiv1products) for validation.

| Field | JSON type | Java type | Required |
|---|---|---|---|
| `sku` | string | `String` | yes |
| `name` | string | `String` | yes |
| `description` | string | `String` | no |
| `price` | number | `BigDecimal` | yes |
| `stockQuantity` | integer | `Integer` | yes |
| `brand` | string | `String` | no |
| `categoryId` | integer | `Long` | no |

### UpdateProductRequest

`dto/UpdateProductRequest.java`. All fields optional; `null` means unchanged.

| Field | JSON type | Java type |
|---|---|---|
| `name` | string | `String` |
| `description` | string | `String` |
| `price` | number | `BigDecimal` |
| `brand` | string | `String` |
| `categoryId` | integer | `Long` |
| `status` | string | `String` |

### StockUpdateRequest

`dto/StockUpdateRequest.java`.

| Field | JSON type | Java type | Required |
|---|---|---|---|
| `delta` | integer | `Integer` | yes |

### CreateCategoryRequest

`dto/CreateCategoryRequest.java`.

| Field | JSON type | Java type | Required |
|---|---|---|---|
| `name` | string | `String` | yes |
| `description` | string | `String` | no |
| `parentCategoryId` | integer | `Long` | no |

### ErrorResponse

`exception/ErrorResponse.java`.

| Field | JSON type | Java type | Notes |
|---|---|---|---|
| `timestamp` | string (date-time) | `LocalDateTime` | |
| `status` | integer | `int` | HTTP status. |
| `error` | string | `String` | Reason phrase. |
| `message` | string | `String` | |
| `path` | string | `String` | Request URI. |
| `correlationId` | string | `String` | From the MDC. |
| `fieldErrors` | array or null | `List<FieldError>` | Only on validation failures; each item has `field` (string) and `message` (string). |

### Page

Spring Data `PageImpl` serialized directly. Fields: `content` (array), `empty` (boolean), `first` (boolean), `last` (boolean), `number` (integer, zero-based page index), `numberOfElements` (integer), `pageable` (object: `offset`, `pageNumber`, `pageSize`, `paged`, `sort`, `unpaged`), `size` (integer), `sort` (object: `empty`, `sorted`, `unsorted`), `totalElements` (integer), `totalPages` (integer). Example under [Conventions](#conventions).
