# API reference

All 53 HTTP endpoints of the platform: how to call them, the conventions they
share, and where the detailed reference for each one lives.

## Three ways in

| You want to… | Use |
|---|---|
| Try requests in a browser | **Swagger UI** at http://localhost:8080/swagger-ui.html. Pick a service from the dropdown. Log in with `POST /api/v1/users/login` in `user-service`, click **Authorize**, and paste the token: it carries over to every service. Requests go through the gateway, so they are authenticated and routed like real traffic. |
| Import into Postman, Insomnia or a code generator | The **OpenAPI 3.1 files** in [openapi/](openapi/): one per service, generated from the running code, with `servers` set to the gateway |
| Understand behaviour, rules and error cases | The **Markdown references** below. They cover what the OpenAPI files can't: business rules, side effects, events and every error path. |

| Service | Markdown reference | OpenAPI | Endpoints |
|---|---|---|---|
| user-service | [user-service.md](user-service.md) | [user-service.json](openapi/user-service.json) | 6 |
| product-service | [product-service.md](product-service.md) | [product-service.json](openapi/product-service.json) | 12 |
| catalog-service | [catalog-service.md](catalog-service.md) | [catalog-service.json](openapi/catalog-service.json) | 7 |
| order-service | [order-service.md](order-service.md) | [order-service.json](openapi/order-service.json) | 9, including a leftover greeting |
| payment-service | [payment-service.md](payment-service.md) | [payment-service.json](openapi/payment-service.json) | 6 |
| shipping-service | [shipping-service.md](shipping-service.md) | [shipping-service.json](openapi/shipping-service.json) | 6 (5 routed + `/hello` on the direct port) |
| review-service | [review-service.md](review-service.md) | [review-service.json](openapi/review-service.json) | 9 |

notification-service has no API, and the gateway and Eureka expose only their
own management endpoints.

To regenerate the OpenAPI files after an API change, start the stack (compose
or Kubernetes) and run `ecommerce-platform/export-openapi.sh`. It fetches each
spec through the gateway, points `servers` at the gateway, and sorts schema
properties so that unchanged APIs produce no diff.

## Conventions

| Topic | Convention |
|---|---|
| Base URL | `http://localhost:8080`, the gateway. The service ports 8081–8087 work too, but they skip authentication and identity headers. Use them for debugging only. |
| Versioning | Every path starts with `/api/v1/`. There is no other version. |
| Authentication | `Authorization: Bearer <JWT>` from `POST /api/v1/users/login`, valid for one hour. Public endpoints are marked in the index. A missing or bad token (or one without `sub` and `exp`) returns **401 with an empty body**, from the gateway. A role other than exactly `ADMIN` on an admin-only route returns **403**; a non-normalised path (`..`, `%2e`, `%2f`, `;`, `//`) returns 400 and any `/internal/` path 404. |
| Identity | The gateway passes `X-Username`, `X-User-Id` and `X-User-Role` to the service. Clients never send these. Services check ownership against `X-Username` (`X-User-Id` in user-service) and the role against exactly `ADMIN`: missing identity is 401, someone else's resource 403. See [Security](../security.md#authorization). |
| Content | `application/json` in both directions. Unknown request fields are **ignored** (Jackson 3 default), so a misspelled field fails silently. |
| Dates | ISO-8601 local date-times without an offset, e.g. `2026-10-29T18:07:12.345678`, in the server's zone (UTC in the containers). Kafka events use a different form; see the [Event catalog](../events.md). |
| Money | JSON numbers. Postgres-backed amounts come back with 4 decimals (`39.9800`), and catalog prices with 2. |
| Enums | sent and returned as their exact upper-case names. A wrong value is a 400. |
| Correlation | Each service echoes `X-Correlation-Id` if it matches `^[A-Za-z0-9._-]{1,64}$`, otherwise generates one, and puts it in error bodies and its own log lines. It isn't propagated between services. |

### Errors

Every service answers errors with the same body:

```json
{
  "timestamp": "2026-10-29T18:07:12.345678",
  "status": 404,
  "error": "Not Found",
  "message": "Order not found: 999",
  "path": "/api/v1/orders/999",
  "correlationId": "3f6c1b8e-5d2a-4c1e-9b7a-2f0d8e4c6a11",
  "fieldErrors": null
}
```

`fieldErrors` lists `{field, message}` pairs on a Bean Validation failure, and
is `null` (or `[]` in catalog-service) otherwise.

| Status | Typically means |
|---|---|
| 400 | validation failed, malformed JSON, a page size over 100, or a non-normalised path at the gateway |
| 401 | gateway: no, invalid or expired token. A service: no identity headers. user-service: bad credentials (one generic message). |
| 403 | the role is not exactly `ADMIN` for an admin-only operation, or the resource belongs to someone else |
| 404 | the resource doesn't exist, or the path matches no gateway route |
| 405 | the path exists, but not for that method |
| 409 | a duplicate (username, email, SKU, review per product, payment, shipment per order), an illegal status transition (order, shipment) or an optimistic-lock conflict |
| 415 / 406 | wrong `Content-Type` / unacceptable `Accept` |
| 429 | user-service login lockout (5 failures in 15 minutes), with `Retry-After` |
| 500 | an unexpected error, with the fixed message `An unexpected error occurred`. Still returned when product-service fails inside review-service, or for an unknown category id in some product-service paths. |
| 502 / 503 | order-service could not use product-service (503 for unreachable, 502 for an unexpected status or price); payment-service could not reach order-service (503) |

The per-service references list the exact status of every error path.

### Pagination

Paged endpoints (`GET /api/v1/products`, `/products/search`, `/catalog`,
`/catalog/search`) take `page` (from 0), `size` and `sort` (`field,asc|desc`)
and return Spring's `Page` serialized directly:

```json
{
  "content": [ ],
  "totalElements": 42, "totalPages": 4, "size": 12, "number": 0, "numberOfElements": 12,
  "first": true, "last": false, "empty": false,
  "pageable": { "pageNumber": 0, "pageSize": 12, "offset": 0, "paged": true, "unpaged": false,
                "sort": { "sorted": false, "unsorted": true, "empty": true } },
  "sort": { "sorted": false, "unsorted": true, "empty": true }
}
```

Other list endpoints return plain, unpaginated JSON arrays.

## Endpoint index

**Gateway** is what the gateway requires: *public* means no token, `ADMIN`
means role exactly `ADMIN` (403 otherwise). **Checks** are the identity-based
checks the service itself applies (owner means `customerId` equals `X-Username`;
user-service compares the path id with `X-User-Id`).

### user-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/users/register` | public | validation, unique username and email | create a `CUSTOMER` account |
| POST | `/api/v1/users/login` | public | credentials (one generic error), lockout | get a JWT |
| GET | `/api/v1/users/me` | JWT | resolves `X-Username` (401 without) | the caller's profile |
| GET | `/api/v1/users/{id}` | JWT | owner or `ADMIN` | a user's profile |
| PUT | `/api/v1/users/{id}` | JWT | owner or `ADMIN` | partial update of a profile |
| DELETE | `/api/v1/users/{id}` | JWT | owner or `ADMIN` | deactivate an account |

### product-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/products` | public | — | page of `ACTIVE` products |
| GET | `/api/v1/products/{id}` | public | — | product by ID, any status |
| GET | `/api/v1/products/sku/{sku}` | public | — | product by SKU |
| GET | `/api/v1/products/search?q=` | public | — | page of `ACTIVE` products whose name contains `q` |
| GET | `/api/v1/products/category/{categoryId}` | public | — | `ACTIVE` products in a category |
| POST | `/api/v1/products` | `ADMIN` | `ADMIN` | create a product |
| PUT | `/api/v1/products/{id}` | `ADMIN` | `ADMIN` | partial update |
| PATCH | `/api/v1/products/{id}/stock` | `ADMIN` | `ADMIN` | adjust stock by `{"delta": n}` |
| DELETE | `/api/v1/products/{id}` | `ADMIN` | `ADMIN` | soft delete |
| GET | `/api/v1/categories` | public | — | all categories |
| GET | `/api/v1/categories/{id}` | public | — | category by ID |
| POST | `/api/v1/categories` | `ADMIN` | `ADMIN` | create a category |

### catalog-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/catalog` | public | — | page of entries |
| GET | `/api/v1/catalog/search?q=` | public | — | relevance-ranked text search |
| GET | `/api/v1/catalog/category/{categoryId}` | public | — | entries in a category |
| GET | `/api/v1/catalog/featured` | public | — | featured entries |
| GET | `/api/v1/catalog/product/{productId}` | public | — | entry by product ID |
| POST | `/api/v1/catalog/sync/{productId}` | `ADMIN` | `ADMIN` | pull a product from product-service into the catalog |
| PATCH | `/api/v1/catalog/product/{productId}` | `ADMIN` | `ADMIN`; validated body | set `featured`, `imageUrl`, `price` |

### order-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/orders?customerId=` | JWT | `customerId` defaults to the caller; others only for `ADMIN` | create a `PENDING` order |
| GET | `/api/v1/orders/{orderId}` | JWT | owner or `ADMIN` | an order with its items |
| GET | `/api/v1/orders/customer/{customerId}` | JWT | that customer or `ADMIN` | a customer's orders |
| POST | `/api/v1/orders/{orderId}/items` | JWT | owner or `ADMIN`; order `PENDING`; quantity 1 to 1000; stock available | add a line and reserve stock |
| POST | `/api/v1/orders/{orderId}/products?productId=&quantity=` | JWT | as above | legacy add-line |
| POST | `/api/v1/orders/{orderId}/confirm` | JWT | owner or `ADMIN`; order `PENDING` with at least one item | confirm, publish `order.placed` |
| PATCH | `/api/v1/orders/{orderId}/status?status=` | `ADMIN` | `ADMIN`; transition table (409) | move a status |
| DELETE | `/api/v1/orders/{orderId}` | JWT | owner or `ADMIN`; not `CANCELLED`/`SHIPPED`/`DELIVERED` | cancel, release stock, publish `order.cancelled` |
| GET | `/api/v1/orders/hello` | JWT | — | greeting (leftover scaffold) |

### payment-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/payments` | JWT | `customerId` is the caller; order `CONFIRMED`, owned by the payer, amount equals the total (503 if order-service is down) | create a `PENDING` payment |
| POST | `/api/v1/payments/{id}/process` | JWT | owner or `ADMIN`; payment `PENDING` | simulated gateway (80 % approve), publish `payment.completed` or `payment.failed` |
| POST | `/api/v1/payments/{id}/refund` | `ADMIN` | `ADMIN`; payment `COMPLETED` | full refund, publish `payment.refunded` |
| GET | `/api/v1/payments/{id}` | JWT | owner or `ADMIN` | a payment |
| GET | `/api/v1/payments/order/{orderId}` | JWT | owner or `ADMIN` | the payment of an order |
| GET | `/api/v1/payments/customer/{customerId}` | JWT | that customer or `ADMIN` | a customer's payments |

### shipping-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/shipments/tracking/{trackingNumber}` | **public**, `GET` only | — | track a parcel (tracking number, status, carrier, ETA and events only) |
| GET | `/api/v1/shipments/order/{orderId}` | JWT | owner or `ADMIN` | the shipment of an order |
| GET | `/api/v1/shipments/{id}/history` | JWT | owner or `ADMIN` | status history, oldest first |
| PATCH | `/api/v1/shipments/{id}/status` | `ADMIN` | `ADMIN`; transition table (409) | set a status, publish `shipment.updated` |
| POST | `/api/v1/shipments` | `ADMIN` | `ADMIN`; one per order (409) | create a shipment by hand (publishes nothing) |

### review-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/reviews/product/{productId}?approvedOnly=` | public | `approvedOnly=false` for `ADMIN` only | a product's reviews (approved only by default) |
| GET | `/api/v1/reviews/product/{productId}/summary` | public | — | average rating and distribution |
| POST | `/api/v1/reviews` | JWT | author = `X-Username`, one per product | create a review (`PENDING`) |
| GET | `/api/v1/reviews/{id}` | JWT | unapproved: author or `ADMIN` | one review |
| GET | `/api/v1/reviews/customer/{customerId}` | JWT | unapproved: that user or `ADMIN` | a user's reviews |
| PUT | `/api/v1/reviews/{id}` | JWT | author only | edit, back to `PENDING` |
| DELETE | `/api/v1/reviews/{id}` | JWT | author or `ADMIN` | delete |
| PATCH | `/api/v1/reviews/{id}/moderate?status=` | `ADMIN` | `ADMIN` | approve or reject |
| POST | `/api/v1/reviews/{id}/vote` | JWT | one vote per user; not your own review; `APPROVED` only | mark helpful or unhelpful |

## Management endpoints

Not part of the public API, but reachable on each service port:
`/actuator/health` (status only), `/info`, `/metrics`, `/prometheus`, `/circuitbreakers`,
`/serviceregistry` (loopback only), plus `/api-docs` and `/swagger-ui.html` on every service.
Service-to-service endpoints under `/internal/v1/` (`PATCH /products/{id}/stock`,
`GET /orders/{id}`) are never routed by the gateway.
Through the gateway, only `/api-docs/<service>` is routed. See
[Security](../security.md#management-and-infrastructure-endpoints) for why the
writable `serviceregistry` endpoint matters.
