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
| invalid request | 400 | `Bad Request` | `Page size must be between 1 and 100`, `Page out of range`, `Invalid value for parameter '<name>'` (also for `q` over 200 characters or with a NUL byte), `Missing required parameter '<name>'`, `Malformed request body` |
| wrong method / content type / `Accept` / unmapped path | 405 / 415 / 406 / 404 | | `Method not allowed` / `Unsupported media type` / `Not acceptable` / `Resource not found` |
| `FeignException.NotFound` (sync of an unknown product) | 404 | `Not Found` | `Product not found in product-service` |
| request body above 1 MB | 413 | `Payload Too Large` | `Request body too large` |
| `ProductServiceErrorException` (product-service answered with something unusable) | 502 | `Bad Gateway` | `Upstream service error` |
| `ProductServiceUnavailableException`, or MongoDB did not answer | 503 | `Service Unavailable` | `Service temporarily unavailable` |
| anything else | 500 | `Internal Server Error` | `An unexpected error occurred` (logged at ERROR with the stack trace, at most once per failure site and 10 s) |

The `502` covers a sync where product-service answers with another 4xx, a 5xx other than 503 and 504, a body that cannot be decoded, or data the sync refuses (an `id` that is not the requested one, a blank `sku` or `name`, a price that is not above 0, has more than 15 integer digits or a scale above 10). The `503` covers a sync where product-service gives no answer (no registered instance, connection failures after three attempts, a read timeout after 10 s, a 503 or 504, an open circuit breaker) and any request that needs MongoDB while it does not answer (no server within 3 s, socket timeout, pool wait, a search that ran past its 4 s `maxTimeMS`). Each of the two is logged as one throttled WARN line without a stack trace. The `413` is written by `filter/RequestSizeLimitFilter` before the request reaches a controller, for a request that declares a `Content-Length` above 1 MB; its body has only `status`, `error` and `message`: `{"status":413,"error":"Payload Too Large","message":"Request body too large"}`. A body that declares no length (chunked) is cut off at 1 MB and answered `400` `Malformed request body`.

"Anything else" is a bug: nothing client-caused (malformed requests, `page < 0`, `size` outside 1 to 100, a NUL byte in `q`) and no dependency failure ends there.

**Pagination.** `GET /api/v1/catalog`, `GET /api/v1/catalog/search`, `GET /api/v1/catalog/category/{categoryId}` and `GET /api/v1/catalog/featured` take two plain integer parameters, `page` (default `0`, zero-based, must be at least 0) and `size` (1 to 100; default `20` for browse and search, `100` for category and featured). A `size` outside 1 to 100, a negative `page`, a non-numeric value or an offset beyond the `int` range is `400`. There is no `sort` parameter: every list is ordered by `productId`, and search puts the best text score first (ties in `productId` order), so page boundaries are stable and no endpoint answers with more than one page. Browse and search answer with a Spring Data `Page` serialized directly, the same shape as product-service's ([Page](product-service.md#page)); category and featured answer with a plain JSON array of the page's entries:

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
    "sort": { "empty": false, "sorted": true, "unsorted": false },
    "unpaged": false
  },
  "size": 20,
  "sort": { "empty": false, "sorted": true, "unsorted": false },
  "totalElements": 1,
  "totalPages": 1
}
```

`sort` reports the page request's own order, `productId` ascending. For search the text score comes first, and that ranking is applied by the query, so it does not show there.

**Dates.** `LocalDateTime` values are ISO-8601 strings without an offset. Entry timestamps have millisecond precision (`2026-10-29T18:07:12.345`; the fraction is omitted when it is zero). The error `timestamp` is not truncated.

**Numbers.** `price` is a JSON number with two decimals (`49.99`, `19.90`).

**JSON names.** The JSON property names are the Kotlin property names of the data classes, unchanged (`productSku`, `productName`, `featured`, `stockStatus`, `imageUrl`, ...). Unknown request properties are ignored, `null` values are written as `null`, and key order in the examples follows the declarations; clients must not depend on it.

**Correlation.** Send `X-Correlation-Id` to have it logged and echoed back; when the header is absent, empty or does not match `^[A-Za-z0-9._-]{1,64}$` the service generates a UUID and returns that instead.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| GET | `/api/v1/catalog/search` | Public | none | Search entries, paged |
| GET | `/api/v1/catalog` | Public | none | Browse all entries, paged |
| GET | `/api/v1/catalog/category/{categoryId}` | Public | none | One page of the entries of one category |
| GET | `/api/v1/catalog/featured` | Public | none | One page of the featured entries |
| GET | `/api/v1/catalog/product/{productId}` | Public | none | Entry by product id |
| POST | `/api/v1/catalog/sync/{productId}` | `ADMIN` | `ADMIN` | Pull a product from product-service and create or refresh its entry |
| PATCH | `/api/v1/catalog/product/{productId}` | `ADMIN` | `ADMIN`; validated body | Set `featured`, `imageUrl`, `price` |

## GET /api/v1/catalog/search

Searches the catalog. When `q` is not blank, MongoDB `$text` runs over `productName` (weight 10), `brand` (5) and `description` (1) with English stemming; any term may match and the best-scoring entries come first. When that finds nothing, or `q` is blank, the service falls back to a case-insensitive substring match on `productName` only. The choice is made per query string from the total number of text hits, so every page of one query uses the same mode. Details and edge cases: [service document, rule 8](../services/catalog-service.md#business-rules).

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `q` | query | string | yes | — | Passed to `$search` unchanged, so `"a phrase"` and `-excluded` work. Missing: 400. Empty matches every entry. At most 200 characters and no NUL byte, otherwise 400 `Invalid value for parameter 'q'`. |
| `page` | query | integer | no | `0` | At least 0, otherwise 400. |
| `size` | query | integer | no | `20` | 1 to 100, otherwise 400. |

**Responses**

- `200 OK` with a [`Page`](#page) of [`CatalogEntryDTO`](#catalogentrydto), best text score first (ties, and the substring fallback, in `productId` order).
- `400` when `q` is missing, longer than 200 characters or contains a NUL byte, or `page`/`size` are out of range or not numbers.
- `503` `Service temporarily unavailable` when MongoDB does not answer, or the search runs past its server-side time limit (`maxTimeMS` 4000, applied to the text search, its count and the substring scan).

**Side effects:** none. Reads only MongoDB.

**Examples**

```bash
# whole words, ranked
curl -s 'http://localhost:8080/api/v1/catalog/search?q=wireless%20mouse'
# a partial word: no text hit, substring fallback finds "Wireless ..."
curl -s 'http://localhost:8080/api/v1/catalog/search?q=wirel&page=0&size=10'
```

## GET /api/v1/catalog

Returns a page of all catalog entries, ordered by `productId`.

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `page` | query | integer | no | `0` | At least 0. |
| `size` | query | integer | no | `20` | 1 to 100. |

**Responses**

- `200 OK` with a [`Page`](#page) of [`CatalogEntryDTO`](#catalogentrydto).
- `400` for `page < 0`, `size` outside 1 to 100 or non-numeric values.
- `503` `Service temporarily unavailable` when MongoDB does not answer.

**Side effects:** none.

**Example**

```bash
curl -s 'http://localhost:8080/api/v1/catalog?page=0&size=20'
```

## GET /api/v1/catalog/category/{categoryId}

Returns one page of the entries whose `categoryId` equals the given id, as a plain JSON array (not a `Page`), ordered by `productId`. Without `page` and `size` that is the first 100 entries; a category with more needs `page=1`, `page=2` and so on. Child categories are not included. An unknown category returns an empty list, not 404 (product-service's equivalent endpoint answers 404).

**Auth:** Public.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `categoryId` | path | integer (int64) | yes | — | Numeric, otherwise 400. |
| `page` | query | integer | no | `0` | At least 0, otherwise 400. |
| `size` | query | integer | no | `100` | 1 to 100, otherwise 400. |

**Responses**

- `200 OK` with an array of at most `size` [`CatalogEntryDTO`](#catalogentrydto), possibly empty.
- `400` for `page < 0`, `size` outside 1 to 100 or non-numeric values.
- `503` `Service temporarily unavailable` when MongoDB does not answer.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/catalog/category/10
curl -s 'http://localhost:8080/api/v1/catalog/category/10?page=1&size=100'
```

## GET /api/v1/catalog/featured

Returns one page of the entries with `featured: true`, as a plain JSON array (not a `Page`), ordered by `productId`. Without `page` and `size` that is the first 100 entries.

**Auth:** Public.

**Query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `page` | query | integer | no | `0` | At least 0, otherwise 400. |
| `size` | query | integer | no | `100` | 1 to 100, otherwise 400. |

**Responses**

- `200 OK` with an array of at most `size` [`CatalogEntryDTO`](#catalogentrydto), possibly empty.
- `400` for `page < 0`, `size` outside 1 to 100 or non-numeric values.
- `503` `Service temporarily unavailable` when MongoDB does not answer.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/catalog/featured
curl -s 'http://localhost:8080/api/v1/catalog/featured?page=1&size=10'
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
- `503` `Service temporarily unavailable` when MongoDB does not answer.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/catalog/product/1
```

## POST /api/v1/catalog/sync/{productId}

Pulls the product from product-service and creates its catalog entry, or refreshes the existing one. This is the only way product data gets into the catalog; nothing calls it automatically.

What it does:

1. `GET /api/v1/products/{productId}` on product-service (Feign through Eureka, behind the circuit breaker `product-service`; connect timeout 2 s, read timeout 10 s, up to 3 attempts on connection failures only, no other retry).
2. Checks the answer: its `id` must be the requested one, `sku` and `name` must not be blank, and `price` must be above 0 with at most 15 integer digits and a scale of at most 10. Otherwise the sync stops with a 502 and nothing is written.
3. `GET /api/v1/categories` on product-service, unless the product has no category. If that fails for any reason the sync continues: an entry whose `categoryId` is unchanged keeps the `categoryName` it already has; a new entry, or one whose category changed, gets `null`.
4. Builds the projection: `productSku`, `productName`, `description`, `brand`, `categoryId` from the product; `categoryName` from the category with the product's `categoryId`; `price` rounded half-up to two decimals; `stockStatus` `OUT_OF_STOCK` for a quantity of 0 or less, `LOW_STOCK` for 1 to 9, `AVAILABLE` for 10 or more. The product's `status` is ignored, but product-service answers 404 for a soft-deleted product to this service, so such a product cannot be synced.
5. Loads the entry. If it exists, overwrites the fields above and `updatedAt`, keeping `featured`, `imageUrl` and `createdAt`; a price set earlier through `PATCH` is replaced. If not, inserts a new entry with `featured: false` and `imageUrl: null`.
6. Saves with a version check. If another write won the race, steps 5 and 6 are repeated (up to 5 attempts in total, with a short random back-off); the product is not fetched again.

**Auth:** `ADMIN`.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `productId` | path | integer (int64) | yes | — | Must exist in product-service and not be soft-deleted there, otherwise 404. |

**Request body:** none.

**Responses**

- `200 OK` with the saved [`CatalogEntryDTO`](#catalogentrydto), for a first sync as well as a refresh.
- `409` `The catalog entry was modified concurrently; re-read it and retry` after five lost races.
- `404` `Product not found in product-service`.
- `502` `Upstream service error` when product-service answers with another 4xx, a 5xx other than 503 and 504 or a body that cannot be decoded, or when its answer fails the checks in step 2.
- `503` `Service temporarily unavailable` when product-service is unreachable or has no registered instance, does not answer within 10 s, answers 503 or 504, or the circuit breaker is open (after repeated failures, or when most of the last calls took longer than 5 s, it rejects calls for 10 s without sending them), and when MongoDB does not answer.

**Side effects:** one or two Feign calls to product-service (the categories call is skipped for a product without a category); one insert or one versioned update in `catalog_entries`; log line `Synced catalog entry for product <productId>`. No events.

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
- `413` `Request body too large` above 1 MB.
- `503` `Service temporarily unavailable` when MongoDB does not answer.

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
| `categoryName` | string | `String?` | yes | `null` when the product has no category, the category is not in product-service's list, or the entry was first synced while the category lookup failed. A failed lookup later keeps the stored name while the `categoryId` is unchanged. |
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
