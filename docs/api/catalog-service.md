# Catalog Service API reference

Base URL through the gateway `http://localhost:8080`; direct (bypasses the gateway, dev only) `http://localhost:8083`. Live OpenAPI from springdoc: `http://localhost:8083/api-docs`, Swagger UI `http://localhost:8083/swagger-ui.html`.

Service overview: [catalog-service](../services/catalog-service.md).

## Conventions

**Content type.** The only request body (`PATCH`) is `application/json`. Every response is `application/json`.

**Authentication.** `GET` requests under `/api/v1/catalog` are public. `POST /api/v1/catalog/sync/{productId}` and `PATCH /api/v1/catalog/product/{productId}` are admin-only: the gateway answers `401` with an empty body without a valid token and `403` unless the role is exactly `ADMIN`; the service checks again (`401` `Authentication required` without `X-Username`, `403` `Access denied` unless `X-User-Role` is `ADMIN`). Requests sent directly to port 8083 skip the gateway. Responses carry `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`; an incoming `X-Correlation-Id` is kept only if it matches `^[A-Za-z0-9._-]{1,64}$`. See the [product-service API reference](product-service.md#conventions) for obtaining a token.

**Error body.** Every error produced by the service has this shape (`exception/ErrorResponse.kt`). `fieldErrors` is always present and, in practice, always empty:

```json
{
  "timestamp": "2026-10-29T18:07:12.345678",
  "status": 404,
  "error": "Not Found",
  "message": "Catalog entry not found for product 999999",
  "path": "/api/v1/catalog/product/999999",
  "correlationId": "5f0c0a8e-0d43-4d44-9a3a-1f0e5b2c7d11",
  "fieldErrors": []
}
```

**Exception to status mapping** (`exception/GlobalExceptionHandler.kt`):

| Exception | Status | `error` | `message` |
|---|---|---|---|
| `CatalogEntryNotFoundException` | 404 | `Not Found` | `Catalog entry not found for product <productId>` |
| `OptimisticLockingFailureException`, `DuplicateKeyException` | 409 | `Conflict` | `The catalog entry was modified concurrently; re-read it and retry` |
| `MethodArgumentNotValidException` | 400 | `Validation Failed` | `Request validation failed`, with `fieldErrors` (the `PATCH` body) |
| `UnauthorizedException` | 401 | `Unauthorized` | `Authentication required` |
| `ForbiddenException` | 403 | `Forbidden` | `Access denied` |
| invalid request | 400 | `Bad Request` | `Page size must be between 1 and 100`, `Invalid value for parameter '<name>'`, `Missing required parameter '<name>'`, `Malformed request body` |
| wrong method / content type / `Accept` / unmapped path | 405 / 415 / 406 / 404 | | `Method not allowed` / `Unsupported media type` / `Not acceptable` / `Resource not found` |
| `FeignException.NotFound` (sync of an unknown product) | 404 | `Not Found` | `Product not found in product-service` |
| anything else | 500 | `Internal Server Error` | `An unexpected error occurred` (logged at ERROR) |

"Anything else" covers:

- failures of the Feign calls during a sync: product-service answering any other 4xx or 5xx, no registered instance (503 from the load balancer), connection failures after three attempts, read timeouts after 10 s;
- nothing client-caused: malformed requests, `page < 0`, `size` outside 1 to 100 and a NUL byte in `q` are `400`.

**Pagination.** `GET /api/v1/catalog` and `GET /api/v1/catalog/search` take two plain integer parameters, `page` (default `0`, zero-based, must be at least 0) and `size` (default `20`, must be at least 1, no upper limit). There is no `sort` parameter: search results come ranked by text score or, in the fallback, in natural order; browse is in natural order. The response is a Spring Data `Page` serialized directly, the same shape as product-service's ([Page](product-service.md#page)):

```json
{
  "content": [ { "id": 1, "productId": 1, "productSku": "SKU-001", "...": "..." } ],
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

`sort` reports "unsorted" even for score-ranked search results, because the ranking is applied by the query, not by the page request.

**Dates.** `LocalDateTime` values are ISO-8601 strings without an offset. Entry timestamps have millisecond precision (`2026-10-29T18:07:12.345`; the fraction is omitted when it is zero). The error `timestamp` is not truncated.

**Numbers.** `price` is a JSON number with two decimals (`49.99`, `19.90`).

**JSON names.** The JSON property names are the Kotlin property names of the data classes, unchanged (`productSku`, `productName`, `featured`, `stockStatus`, `imageUrl`, ...). Unknown request properties are ignored, `null` values are written as `null`, and key order in the examples follows the declarations; clients must not depend on it.

**Correlation.** Send `X-Correlation-Id` to have it logged and echoed back; when the header is absent the service generates a UUID and returns it. An empty header value is used as it is.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| GET | `/api/v1/catalog/search` | Public | none | Search entries, paged |
| GET | `/api/v1/catalog` | Public | none | Browse all entries, paged |
| GET | `/api/v1/catalog/category/{categoryId}` | Public | none | Entries of one category |
| GET | `/api/v1/catalog/featured` | Public | none | Featured entries |
| GET | `/api/v1/catalog/product/{productId}` | Public | none | Entry by product id |
| POST | `/api/v1/catalog/sync/{productId}` | `ADMIN` | `ADMIN` | Pull a product from product-service and create or refresh its entry |
| PATCH | `/api/v1/catalog/product/{productId}` | `ADMIN` | `ADMIN`; validated body | Set `featured`, `imageUrl`, `price` |

## GET /api/v1/catalog/search

Searches the catalog. When `q` is not blank, MongoDB `$text` runs over `productName` (weight 10), `brand` (5) and `description` (1) with English stemming; any term may match and the best-scoring entries come first. When that finds nothing, or `q` is blank, the service falls back to a case-insensitive substring match on `productName` only. The choice is made per query string from the total number of text hits, so every page of one query uses the same mode. Details and edge cases: [service document, rule 8](../services/catalog-service.md#business-rules).

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `q` | query | string | yes | — | Passed to `$search` unchanged, so `"a phrase"` and `-excluded` work. Missing: 400. Empty matches every entry. A NUL byte is 400. |
| `page` | query | integer | no | `0` | At least 0, otherwise 400. |
| `size` | query | integer | no | `20` | 1 to 100, otherwise 400. |

**Responses**

- `200 OK` with a [`Page`](#page) of [`CatalogEntryDTO`](#catalogentrydto).
- `400` when `q` is missing, or `page`/`size` are out of range or not numbers.

**Side effects:** none. Reads only MongoDB.

**Examples**

```bash
# whole words, ranked
curl -s 'http://localhost:8080/api/v1/catalog/search?q=wireless%20mouse'
# a partial word: no text hit, substring fallback finds "Wireless ..."
curl -s 'http://localhost:8080/api/v1/catalog/search?q=wirel&page=0&size=10'
```

## GET /api/v1/catalog

Returns a page of all catalog entries, in MongoDB's natural order (no sort).

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `page` | query | integer | no | `0` | At least 0. |
| `size` | query | integer | no | `20` | 1 to 100. |

**Responses**

- `200 OK` with a [`Page`](#page) of [`CatalogEntryDTO`](#catalogentrydto).
- `400` for `page < 0`, `size` outside 1 to 100 or non-numeric values.

**Side effects:** none.

**Example**

```bash
curl -s 'http://localhost:8080/api/v1/catalog?page=0&size=20'
```

## GET /api/v1/catalog/category/{categoryId}

Returns every entry whose `categoryId` equals the given id, as a plain list (not paged, no defined order). Child categories are not included. An unknown category returns an empty list, not 404 (product-service's equivalent endpoint answers 404).

**Auth:** Public.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `categoryId` | path | integer (int64) | yes | — | Numeric, otherwise 400. |

**Responses**

- `200 OK` with an array of [`CatalogEntryDTO`](#catalogentrydto), possibly empty.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/catalog/category/10
```

## GET /api/v1/catalog/featured

Returns every entry with `featured: true`, as a plain list (not paged, no defined order).

**Auth:** Public.

**Responses**

- `200 OK` with an array of [`CatalogEntryDTO`](#catalogentrydto), possibly empty.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/catalog/featured
```

## GET /api/v1/catalog/product/{productId}

Returns the catalog entry of one product.

**Auth:** Public.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `productId` | path | integer (int64) | yes | — | Numeric, otherwise 400. |

**Responses**

- `200 OK` with [`CatalogEntryDTO`](#catalogentrydto).

  ```json
  {
    "id": 1,
    "productId": 1,
    "productSku": "SKU-001",
    "productName": "Wireless Mouse",
    "description": "Ergonomic wireless mouse",
    "price": 49.99,
    "brand": "Logi",
    "categoryId": 10,
    "categoryName": "Electronics",
    "featured": false,
    "stockStatus": "AVAILABLE",
    "imageUrl": null,
    "createdAt": "2026-10-29T18:07:12.345",
    "updatedAt": "2026-10-29T18:07:12.345"
  }
  ```
- `404` `Catalog entry not found for product <productId>` when the product was never synced (whether or not it exists in product-service).

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/catalog/product/1
```

## POST /api/v1/catalog/sync/{productId}

Pulls the product from product-service and creates its catalog entry, or refreshes the existing one. This is the only way product data gets into the catalog; nothing calls it automatically.

What it does:

1. `GET /api/v1/products/{productId}` on product-service (Feign through Eureka; connect timeout 2 s, read timeout 10 s, up to 3 attempts on connection failures only).
2. `GET /api/v1/categories` on product-service; if that fails for any reason the sync continues without a category name.
3. Builds the projection: `productSku`, `productName`, `description`, `brand`, `categoryId` from the product; `categoryName` from the category with the product's `categoryId`; `price` rounded half-up to two decimals; `stockStatus` `OUT_OF_STOCK` for a quantity of 0 or less, `LOW_STOCK` for 1 to 9, `AVAILABLE` for 10 or more. The product's `status` is ignored, so soft-deleted products are synced too.
4. Loads the entry. If it exists, overwrites the fields above and `updatedAt`, keeping `featured`, `imageUrl` and `createdAt`; a price set earlier through `PATCH` is replaced. If not, inserts a new entry with `featured: false` and `imageUrl: null`.
5. Saves with a version check. If another write won the race, steps 4 and 5 are repeated (up to 5 attempts in total, with a short random back-off); the product is not fetched again.

**Auth:** `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `productId` | path | integer (int64) | yes | — | Must exist in product-service, otherwise 404. |

**Request body:** none.

**Responses**

- `200 OK` with the saved [`CatalogEntryDTO`](#catalogentrydto), for a first sync as well as a refresh.
- `409` `The catalog entry was modified concurrently; re-read it and retry` after five lost races.
- `404` `Product not found in product-service`.
- `500` `An unexpected error occurred` when product-service is unreachable or has no registered instance, when it does not answer within 10 s, or when it answers with an error.

**Side effects:** two Feign calls to product-service; one insert or one versioned update in `catalog_entries`; log line `Synced catalog entry for product <productId>`. No events.

**Example**

```bash
curl -s -X POST http://localhost:8080/api/v1/catalog/sync/1 -H "Authorization: Bearer $TOKEN"
```

## PATCH /api/v1/catalog/product/{productId}

Updates the catalog-owned fields of an existing entry. Each non-null field is applied; a `null` or absent field is left unchanged (an empty `imageUrl` clears it). `featured: false` is applied, because `false` is not `null`. An empty object only updates `updatedAt`. The body is validated (below).

The write is version-checked. If another write changed the entry between this request's read and its write, the request fails with 409 and nothing is written; it is not retried. The version is not exposed, so the check cannot detect changes made since the client's own earlier read.

A price set here lasts only until the next sync of the product, which replaces it with product-service's price.

**Auth:** `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `productId` | path | integer (int64) | yes | — | The entry must exist (404). |

**Request body** `UpdateCatalogEntryRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `featured` | boolean | no | none | |
| `imageUrl` | string | no | `@Size(max = 2048)`; `@Pattern` absolute `http(s)` URL | `javascript:`, `data:`, `file:` and protocol-relative URLs are 400. An empty string clears the image; `null` leaves it. |
| `price` | number | no | `@DecimalMin("0", exclusive)` "price must be greater than 0"; `@Digits(15, 2)` | Zero, negative values and more than 2 decimals are 400. |

```json
{ "featured": true, "imageUrl": "https://cdn.example.com/img/sku-001.png", "price": 44.99 }
```

**Responses**

- `200 OK` with the updated [`CatalogEntryDTO`](#catalogentrydto) (here `"price": 44.99`).
- `404` `Catalog entry not found for product <productId>`.
- `409` `The catalog entry was modified concurrently; re-read it and retry`.
- `400` for a validation failure (`fieldErrors`), a missing or malformed body or a non-numeric `productId`.

**Side effects:** one versioned update of the entry. No events; product-service is not called.

**Example**

```bash
curl -s -X PATCH http://localhost:8080/api/v1/catalog/product/1 \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"featured":true}'
```

## Schemas

### CatalogEntryDTO

`dto/CatalogEntryDTO.kt`. Returned by every endpoint except on errors.

| Field | JSON type | Kotlin type | Nullable | Notes |
|---|---|---|---|---|
| `id` | integer | `Long` | no | Always equals `productId`; kept for compatibility with the former relational model. |
| `productId` | integer | `Long` | no | Document `_id`. |
| `productSku` | string | `String` | no | From product-service `sku`. |
| `productName` | string | `String` | no | From product-service `name`. |
| `description` | string | `String?` | yes | |
| `price` | number | `BigDecimal` | no | Two decimals. Product price or a `PATCH` override, whichever was written last. |
| `brand` | string | `String?` | yes | |
| `categoryId` | integer | `Long?` | yes | |
| `categoryName` | string | `String?` | yes | `null` when the product has no category or the category lookup failed during the last sync. |
| `featured` | boolean | `Boolean` | no | Catalog-owned. |
| `stockStatus` | string | `StockStatus` | no | `AVAILABLE`, `LOW_STOCK` or `OUT_OF_STOCK`, as of the last sync. |
| `imageUrl` | string | `String?` | yes | Catalog-owned. |
| `createdAt` | string (date-time) | `LocalDateTime` | no | First sync. |
| `updatedAt` | string (date-time) | `LocalDateTime` | no | Last sync or `PATCH`. |

### StockStatus

| Value | Product `stockQuantity` at the last sync |
|---|---|
| `OUT_OF_STOCK` | 0 or less |
| `LOW_STOCK` | 1 to 9 |
| `AVAILABLE` | 10 or more |

### UpdateCatalogEntryRequest

`dto/UpdateCatalogEntryRequest.kt`. All properties are nullable with a `null` default.

| Field | JSON type | Kotlin type |
|---|---|---|
| `featured` | boolean | `Boolean?` |
| `imageUrl` | string | `String?` |
| `price` | number | `BigDecimal?` |

### ErrorResponse

`exception/ErrorResponse.kt`.

| Field | JSON type | Kotlin type | Notes |
|---|---|---|---|
| `timestamp` | string (date-time) | `LocalDateTime` | |
| `status` | integer | `Int` | HTTP status. |
| `error` | string | `String` | |
| `message` | string | `String` | |
| `path` | string | `String` | Request URI. |
| `correlationId` | string | `String?` | From the MDC. |
| `fieldErrors` | array | `List<FieldError>` | Defaults to `[]`; items would have `field` and `message` (strings). |

### Page

Spring Data `PageImpl` serialized directly: `content`, `empty`, `first`, `last`, `number`, `numberOfElements`, `pageable` (`offset`, `pageNumber`, `pageSize`, `paged`, `sort`, `unpaged`), `size`, `sort` (`empty`, `sorted`, `unsorted`), `totalElements`, `totalPages`. Example under [Conventions](#conventions).

### Inbound DTOs (from product-service)

Used only to decode product-service's responses during a sync; not part of this service's API. Fields product-service sends but these classes do not declare are ignored.

| Class | Properties |
|---|---|
| `dto/ProductDTO.kt` | `id: Long`, `sku: String`, `name: String`, `description: String?`, `price: BigDecimal`, `stockQuantity: Int`, `brand: String?`, `categoryId: Long?`, `status: String` |
| `dto/CategoryDTO.kt` | `id: Long`, `name: String`, `description: String?`, `parentCategoryId: Long?` |
