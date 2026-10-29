# API reference

All 54 HTTP endpoints of the platform: how to call them, the conventions they
share, and where the detailed reference for each one lives.

## Three ways in

| You want to… | Use |
|---|---|
| Try requests in a browser | **Swagger UI** at http://localhost:8080/swagger-ui.html. Pick a service from the dropdown. Log in with `POST /api/v1/users/login` in `user-service`, click **Authorize**, and paste the token: it carries over to every service. Requests go through the gateway, so they are authenticated and routed like real traffic. |
| Import into Postman, Insomnia or a code generator | The **OpenAPI 3.1 files** in [openapi/](openapi/): one per service, generated from the running code, with `servers` set to the gateway |
| Understand behaviour, rules and error cases | The **Markdown references** below. They cover what the OpenAPI files can't: business rules, side effects, events and every error path. |

| Service | Markdown reference | OpenAPI | Endpoints |
|---|---|---|---|
| user-service | [user-service.md](user-service.md) | [user-service.json](openapi/user-service.json) | 7 |
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
| Authentication | `Authorization: Bearer <JWT>` from `POST /api/v1/users/login`, valid for one hour. Public endpoints are marked in the index. A missing or bad token returns **401 with an empty body**, from the gateway. |
| Identity | The gateway passes `X-Username`, `X-User-Id` and `X-User-Role` to the service. Clients never send these. Few endpoints act on them: see [Security](../security.md#authorization). |
| Content | `application/json` in both directions. Unknown request fields are **ignored** (Jackson 3 default), so a misspelled field fails silently. |
| Dates | ISO-8601 local date-times without an offset, e.g. `2026-10-29T18:07:12.345678`, in the server's zone (UTC in the containers). Kafka events use a different form; see the [Event catalog](../events.md). |
| Money | JSON numbers. Postgres-backed amounts come back with 4 decimals (`39.9800`), and catalog prices with 2. |
| Enums | sent and returned as their exact upper-case names. A wrong value is often a **500**, not a 400 (`valueOf` without a handler). |
| Correlation | Each service echoes `X-Correlation-Id`, or generates one, and puts it in error bodies and its own log lines. It isn't propagated between services. |

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
| 400 | validation failed, malformed JSON, or an illegal state transition (order-service uses 400, never 409, for transitions) |
| 401 | gateway: no, invalid or expired token. user-service: bad credentials or inactive account. |
| 404 | the resource doesn't exist, or the path matches no gateway route |
| 405 | the path exists, but not for that method |
| 409 | a duplicate (username, email, SKU, review per product, completed payment) or an optimistic-lock conflict (catalog) |
| 500 | an unexpected error. It is also returned for several client mistakes the handlers don't map: unknown enum values, a wrong `Content-Type`, unmapped paths in some services, shipping-service validation errors, and a product-service 404 seen through catalog- or review-service. |
| 502 / 503 | order-service could not use product-service (503 for unreachable, 502 for an unexpected status) |

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

**Gateway** is what the gateway requires: *public* means no token. **Checks**
are the identity-based checks the service itself applies. "None" means any
authenticated caller may act on any record.

### user-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/users/register` | public | validation, unique username and email | create a `CUSTOMER` account |
| POST | `/api/v1/users/login` | public | credentials, account status | get a JWT |
| GET | `/api/v1/users/me` | JWT | resolves `X-Username` | the caller's profile |
| GET | `/api/v1/users/{id}` | JWT | none | any user's profile |
| PUT | `/api/v1/users/{id}` | JWT | none | partial update of any profile |
| DELETE | `/api/v1/users/{id}` | JWT | none | deactivate any account |
| GET | `/api/v1/users/internal/{username}` | **public** | none | any full profile, by username |

### product-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/products` | public | — | page of `ACTIVE` products |
| GET | `/api/v1/products/{id}` | public | — | product by ID, any status |
| GET | `/api/v1/products/sku/{sku}` | public | — | product by SKU |
| GET | `/api/v1/products/search?q=` | public | — | page of `ACTIVE` products whose name contains `q` |
| GET | `/api/v1/products/category/{categoryId}` | public | — | `ACTIVE` products in a category |
| POST | `/api/v1/products` | JWT | none (meant for admins) | create a product |
| PUT | `/api/v1/products/{id}` | JWT | none (meant for admins) | partial update |
| PATCH | `/api/v1/products/{id}/stock` | JWT | none | adjust stock by `{"delta": n}` (used by order-service) |
| DELETE | `/api/v1/products/{id}` | JWT | none (meant for admins) | soft delete |
| GET | `/api/v1/categories` | public | — | all categories |
| GET | `/api/v1/categories/{id}` | public | — | category by ID |
| POST | `/api/v1/categories` | JWT | none (meant for admins) | create a category |

### catalog-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/catalog` | public | — | page of entries |
| GET | `/api/v1/catalog/search?q=` | public | — | relevance-ranked text search |
| GET | `/api/v1/catalog/category/{categoryId}` | public | — | entries in a category |
| GET | `/api/v1/catalog/featured` | public | — | featured entries |
| GET | `/api/v1/catalog/product/{productId}` | public | — | entry by product ID |
| POST | `/api/v1/catalog/sync/{productId}` | JWT | none | pull a product from product-service into the catalog |
| PATCH | `/api/v1/catalog/product/{productId}` | JWT | none | set `featured`, `imageUrl`, `price` |

### order-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/orders?customerId=` | JWT | none (`customerId` comes from the caller) | create a `PENDING` order |
| GET | `/api/v1/orders/{orderId}` | JWT | none | an order with its items |
| GET | `/api/v1/orders/customer/{customerId}` | JWT | none | a customer's orders |
| POST | `/api/v1/orders/{orderId}/items` | JWT | order not `CANCELLED`/`PAID`, stock available | add a line and reserve stock |
| POST | `/api/v1/orders/{orderId}/products?productId=&quantity=` | JWT | as above, quantity **not** validated | legacy add-line |
| POST | `/api/v1/orders/{orderId}/confirm` | JWT | order `PENDING` with at least one item | confirm, publish `order.placed` |
| PATCH | `/api/v1/orders/{orderId}/status?status=` | JWT | none (any transition) | set a status, meant for admins |
| DELETE | `/api/v1/orders/{orderId}` | JWT | not `SHIPPED`/`DELIVERED` | cancel, release stock, publish `order.cancelled` |
| GET | `/api/v1/orders/hello` | JWT | — | greeting (leftover scaffold) |

### payment-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| POST | `/api/v1/payments` | JWT | none (amount, order and customer come from the caller) | create a `PENDING` payment |
| POST | `/api/v1/payments/{id}/process` | JWT | payment `PENDING` | simulated gateway (80 % approve), publish `payment.completed` or `payment.failed` |
| POST | `/api/v1/payments/{id}/refund` | JWT | payment `COMPLETED` | full refund, publish `payment.refunded` |
| GET | `/api/v1/payments/{id}` | JWT | none | a payment |
| GET | `/api/v1/payments/order/{orderId}` | JWT | none | the payment of an order |
| GET | `/api/v1/payments/customer/{customerId}` | JWT | none | a customer's payments |

### shipping-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/shipments/tracking/{trackingNumber}` | **public**, any method | — | track a parcel (includes customer ID and addresses) |
| GET | `/api/v1/shipments/order/{orderId}` | JWT | none | the shipment of an order |
| GET | `/api/v1/shipments/{id}/history` | JWT | none | status history, oldest first |
| PATCH | `/api/v1/shipments/{id}/status` | JWT | not already `DELIVERED`/`RETURNED` | set a status, publish `shipment.updated` |
| POST | `/api/v1/shipments` | JWT | none | create a shipment by hand (publishes nothing) |

### review-service

| Method | Path | Gateway | Checks | Purpose |
|---|---|---|---|---|
| GET | `/api/v1/reviews/product/{productId}?approvedOnly=` | public | — | a product's reviews (approved only by default) |
| GET | `/api/v1/reviews/product/{productId}/summary` | public | — | average rating and distribution |
| POST | `/api/v1/reviews` | JWT | author = `X-Username`, one per product | create a review (`PENDING`) |
| GET | `/api/v1/reviews/{id}` | JWT | none | one review, any status |
| GET | `/api/v1/reviews/customer/{customerId}` | JWT | none | a user's reviews |
| PUT | `/api/v1/reviews/{id}` | JWT | author only | edit, back to `PENDING` |
| DELETE | `/api/v1/reviews/{id}` | JWT | author or `ADMIN` | delete |
| PATCH | `/api/v1/reviews/{id}/moderate?status=` | JWT | **none** | approve or reject |
| POST | `/api/v1/reviews/{id}/vote` | JWT | one vote per user | mark helpful or unhelpful |

## Management endpoints

Not part of the public API, but reachable on each service port:
`/actuator/health`, `/info`, `/metrics`, `/prometheus`, `/circuitbreakers`,
`/serviceregistry`, plus `/api-docs` and `/swagger-ui.html` on every service.
Through the gateway, only `/api-docs/<service>` is routed. See
[Security](../security.md#management-and-infrastructure-endpoints) for why the
writable `serviceregistry` endpoint matters.
