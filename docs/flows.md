# End-to-end flows

How the services work together for each user journey: every call in order,
what each step writes, which events fire, and where the flow is known to go
wrong. Paths are as the client sends them to the gateway, which forwards them
unchanged. The browser's side of each flow (pages, hooks, local state) is in
[Frontend](frontend.md#key-user-flows), and each service's internals are on its
own page.

Throughout, **JWT** means the gateway requires `Authorization: Bearer <token>`
and injects `X-Username`, `X-User-Id` and `X-User-Role`. **Public** means it
doesn't.

## 1. Registration and login

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant U as user-service
    participant DB as userdb
    B->>G: POST /api/v1/users/register (public)
    G->>U: forward
    U->>U: validate (username 3-50 chars [a-zA-Z0-9_], email, password min 8)
    U->>DB: username and email taken? (409 if so)
    U->>DB: INSERT app_users (BCrypt hash, role CUSTOMER, status ACTIVE)
    U-->>B: 201 UserDTO
    B->>G: POST /api/v1/users/login (public)
    G->>U: forward
    U->>DB: load user. 401 if unknown, not ACTIVE, or wrong password
    U->>U: sign JWT (sub=username, userId, role, exp=1h)
    U-->>B: 200 token, expiresIn=3600, username, role
    Note over B: token, username and role persisted in localStorage (auth-storage)
    B->>G: GET /api/v1/users/me + Bearer token (JWT)
    G->>G: verify signature and expiry, set X-Username etc.
    G->>U: forward with identity headers
    U->>DB: find by X-Username
    U-->>B: 200 UserDTO
```

- The SPA takes the role from the login response. It never decodes the token. Admin pages are hidden client-side only (see [Security](security.md)).
- An `admin`/`admin` account is seeded on every start of user-service, and it is the only way an `ADMIN` exists.
- Tokens can't be revoked. Deactivating a user (`DELETE /api/v1/users/{id}`) leaves their token valid until it expires.

## 2. Browsing and product detail

All reads are public.

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant P as product-service
    participant R as review-service
    B->>G: GET /api/v1/products?page=0&size=12 (public)
    G->>P: forward
    P-->>B: Page of ACTIVE products
    B->>G: GET /api/v1/categories (public)
    G->>P: forward
    P-->>B: all categories
    B->>G: GET /api/v1/products/{id} (public)
    G->>P: forward
    P-->>B: ProductDTO, any status
    B->>G: GET /api/v1/reviews/product/{id} (public, approvedOnly=true by default)
    G->>R: forward
    R-->>B: APPROVED reviews with vote counts
    B->>G: GET /api/v1/reviews/product/{id}/summary (public)
    G->>R: forward
    R-->>B: average (APPROVED only), distribution, totalReviews (all statuses)
```

- Listings, search (`/products/search?q=`, a name-contains match) and category pages return only `ACTIVE` products. Out-of-stock and soft-deleted products disappear from every list, the admin table included.
- The storefront does **not** read from catalog-service. The catalog read model is complete and reachable at `/api/v1/catalog/**`, but nothing in the SPA calls it (flow 3).

## 3. Catalog synchronization

catalog-service holds one MongoDB document per product, filled on demand.

```mermaid
sequenceDiagram
    autonumber
    participant C as Caller (any JWT)
    participant G as api-gateway
    participant CS as catalog-service
    participant P as product-service
    participant M as catalogdb (MongoDB)
    C->>G: POST /api/v1/catalog/sync/{productId} (JWT)
    G->>CS: forward
    CS->>P: Feign GET /api/v1/products/{productId}
    CS->>P: Feign GET /api/v1/categories (a failure here becomes an empty list)
    CS->>CS: derive stockStatus (0 OUT_OF_STOCK, below 10 LOW_STOCK, else AVAILABLE)
    CS->>M: upsert catalog_entries _id=productId (optimistic lock, up to 5 retries)
    CS-->>C: 200 CatalogEntryDTO
    C->>G: GET /api/v1/catalog/search?q=... (public)
    G->>CS: forward
    CS->>M: $text search (name 10, brand 5, description 1), regex fallback
    CS-->>C: Page of entries
```

- **Nothing triggers a sync automatically.** There is no Kafka consumer and no scheduler. A product change reaches the catalog only when someone calls `sync` for that product, and a deleted product's entry is never removed.
- A re-sync keeps the catalog-only `featured` and `imageUrl`, but **overwrites `price`** with product-service's price, so a price set through `PATCH /api/v1/catalog/product/{id}` lasts only until the next sync.
- Any product-service failure, including a 404, surfaces as a 500. The Feign circuit breaker and fallback are configured but not enabled.

## 4. Building a cart

The cart is not client-side state. It is an order in status `PENDING`, and the
browser stores only its ID. Adding to the cart **reserves stock immediately**.

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant O as order-service
    participant P as product-service
    participant ODB as orderdb
    Note over B: first Add to Cart, no cartOrderId yet
    B->>G: POST /api/v1/orders?customerId={username} (JWT)
    G->>O: forward
    O->>ODB: INSERT orders (status PENDING, total 0)
    O-->>B: 201 OrderDTO, then stores cartOrderId
    B->>G: POST /api/v1/orders/{orderId}/items with productId and quantity (JWT)
    G->>O: forward
    O->>P: Feign GET /api/v1/products/{productId} (404 if unknown)
    O->>O: stockQuantity >= quantity? (400 if not)
    O->>P: Feign PATCH /api/v1/products/{productId}/stock with delta = -quantity
    P->>P: read, check, write stock (no lock). Status OUT_OF_STOCK at 0
    O->>ODB: INSERT order_items (snapshot of name and price), total += price x qty
    O-->>B: 200 OrderDTO
```

- `customerId` is whatever the client sends. The SPA sends the username, while the smoke test sends `1`. order-service never compares it with the caller's identity.
- There is no endpoint to remove a line. The SPA cancels the whole order and rebuilds it (flow 6), and every rebuild leaves a cancelled order in the history.
- Stock is reserved per line and released only by an explicit cancel. An abandoned cart, a logout or a second browser keeps the reservation forever.
- product-service's stock update is a read-modify-write with no locking, so two concurrent reservations can both succeed against the same last unit.

## 5. Checkout and payment

The client orchestrates the purchase with three calls in sequence. Kafka
carries the outcome to the other services.

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant O as order-service
    participant PS as payment-service
    participant K as Kafka
    participant S as shipping-service
    participant N as notification-service
    B->>G: POST /api/v1/orders/{id}/confirm (JWT)
    G->>O: forward
    O->>O: must be PENDING with at least one item (400 otherwise)
    O->>K: order.placed (sent inside the DB transaction)
    O-->>B: 200 OrderDTO status CONFIRMED with totalAmount
    K-->>N: order.placed, logged
    B->>G: POST /api/v1/payments with orderId, customerId, amount=totalAmount, method, cardLastFour (JWT)
    G->>PS: forward
    PS->>PS: 409 only if this order already has a COMPLETED payment
    PS-->>B: 201 PaymentDTO status PENDING
    B->>G: POST /api/v1/payments/{paymentId}/process (JWT)
    G->>PS: forward
    PS->>PS: random draw, 80 percent approve
    alt approved
        PS->>K: payment.completed
        PS-->>B: 200 PaymentDTO status COMPLETED
        K-->>O: order status PAID
        K-->>S: create shipment (PENDING, DHL, ETA +5 days, placeholder addresses)
        S->>K: shipment.created
        K-->>N: payment.completed and shipment.created, logged
    else declined
        PS->>K: payment.failed
        PS-->>B: 200 PaymentDTO status FAILED
        K-->>O: order status CANCELLED (stock stays reserved)
        K-->>N: payment.failed, logged
    end
    Note over B: the SPA shows Order Placed in both cases and clears cartOrderId
```

What a successful purchase leaves behind:

| Service | Record | State after the flow |
|---|---|---|
| order-service | `orders` + `order_items` | `PAID`. Addresses null: the checkout form's addresses are never sent. |
| product-service | `products.stock_quantity` | reduced at add-to-cart time |
| payment-service | `payments` | `COMPLETED`, `transaction_id` set |
| shipping-service | `shipments` + one `shipment_events` row | `PENDING`. Origin `Warehouse, 123 Storage St`, destination `Customer Address`. |
| notification-service | — | three log lines (`order.placed`, `payment.completed`, `shipment.created`) |

Known gaps in this flow:

- **The amount is the client's word.** payment-service never checks that the order exists, is `CONFIRMED`, belongs to the caller, or costs `amount`. order-service marks the order `PAID` on any `payment.completed`, whatever its current status. One cent "pays" for any order, including an unconfirmed or cancelled one.
- **A declined payment cancels the order but keeps its stock reserved**, and it publishes no `order.cancelled`. With an 80 % success rate, about one checkout in five leaks stock.
- The SPA never reads the payment status, so a decline is shown as success.
- The order never moves past `PAID` by itself. Shipment events are not consumed by order-service (flow 8).
- If any call after `confirm` fails, the cart order is stuck in `CONFIRMED`, and retrying fails with 400. See [Frontend](frontend.md#cart-checkout-order-creation-and-payment).

## 6. Cancellation

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant O as order-service
    participant P as product-service
    participant K as Kafka
    participant N as notification-service
    B->>G: DELETE /api/v1/orders/{id} (JWT)
    G->>O: forward
    O->>O: 400 if SHIPPED or DELIVERED (any other status is accepted, CANCELLED too)
    loop each order item
        O->>P: Feign PATCH /api/v1/products/{productId}/stock with delta = +quantity
        Note over O,P: failures are logged and swallowed
    end
    O->>O: status CANCELLED
    O->>K: order.cancelled
    O-->>B: 204
    K-->>N: order.cancelled, logged
```

- Cancelling a **paid** order neither refunds the payment nor stops the shipment. Nothing listens to `order.cancelled` except notification-service.
- Cancelling an **already cancelled** order is accepted. It releases the stock again and republishes the event, so repeated cancels inflate stock.
- A stock release that fails (product-service down) is lost. The order still ends up `CANCELLED`.

## 7. Refund

`POST /api/v1/payments/{id}/refund` (JWT) moves a `COMPLETED` payment to
`REFUNDED` for its full amount and publishes `payment.refunded`. Only
notification-service consumes it: the order stays `PAID`, the shipment carries
on, and stock is untouched. No page in the SPA calls this endpoint, and nothing
checks who is asking.

## 8. Shipping progress and tracking

```mermaid
sequenceDiagram
    autonumber
    participant A as Operator (any JWT)
    participant V as Visitor
    participant G as api-gateway
    participant S as shipping-service
    participant K as Kafka
    participant N as notification-service
    A->>G: PATCH /api/v1/shipments/{id}/status with status, location, description (JWT)
    G->>S: forward
    S->>S: 400 if already DELIVERED or RETURNED. Any other jump is allowed
    S->>S: update status, append shipment_events row, set actualDelivery when DELIVERED
    S->>K: shipment.updated
    S-->>A: 200 ShipmentDTO
    K-->>N: shipment.updated, logged
    V->>G: GET /api/v1/shipments/tracking/{trackingNumber} (public)
    G->>S: forward
    S-->>V: ShipmentDTO (includes orderId, customerId, both addresses)
    V->>G: GET /api/v1/shipments/{id}/history (JWT required)
    G-->>V: 401 for an anonymous visitor. The SPA then redirects to login
```

- Nothing advances a shipment automatically: no scheduler, no carrier integration, and no page in the SPA. Statuses change only through this PATCH.
- order-service never hears about shipment progress, so orders stay `PAID`. `SHIPPED` and `DELIVERED` are reachable only through `PATCH /api/v1/orders/{id}/status`, which applies any status without checks or side effects.

## 9. Reviews

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant R as review-service
    participant P as product-service
    B->>G: POST /api/v1/reviews with productId, rating 1-5, title, body (JWT)
    G->>R: forward with X-Username
    R->>P: Feign GET /api/v1/products/{productId} (existence check)
    Note over R,P: a 404 or an outage both become 500
    R->>R: one review per (product, X-Username), 409 otherwise
    R-->>B: 201 ReviewDTO status PENDING
    B->>G: PATCH /api/v1/reviews/{id}/moderate?status=APPROVED (JWT)
    G->>R: forward
    R-->>B: 200 (no role check: any user can approve or reject any review)
    B->>G: POST /api/v1/reviews/{id}/vote with helpful true or false (JWT)
    G->>R: forward
    R-->>B: 200 (one vote per user, re-voting flips it, voting on your own review is allowed)
```

- Editing a review (`PUT`, author only) sends it back to `PENDING`. Deleting is allowed for the author or a caller with `X-User-Role: ADMIN`.
- The product page loads approved reviews only, so authors don't see their own pending review. Submitting again returns 409.
- There is no verified-purchase check. review-service never asks order-service whether the author bought the product.

## 10. Administration

The SPA's admin area (`/admin/**`) manages products, categories, orders and
reviews. The backend has **no role checks** on any of the endpoints it uses:
product and category writes, `PATCH /api/v1/orders/{id}/status`, review
moderation, catalog writes, shipment status and refunds all accept any valid
token. "Admin" is a UI convention, not a permission. Some admin screens also
have no backing endpoint (listing all orders, listing pending reviews). See
[Frontend: admin flows](frontend.md#admin-flows) and [Findings](findings.md).

## Status models side by side

```mermaid
stateDiagram-v2
    state "Order (order-service)" as Order {
        [*] --> PENDING
        PENDING --> CONFIRMED: confirm
        CONFIRMED --> PAID: payment.completed
        CONFIRMED --> CANCELLED: payment.failed or DELETE
        PENDING --> CANCELLED: DELETE
        PAID --> CANCELLED: DELETE
        PAID --> SHIPPED: PATCH status
        SHIPPED --> DELIVERED: PATCH status
    }
```

| Entity | Statuses | Changed by |
|---|---|---|
| Order | `PENDING`, `CONFIRMED`, `PAID`, `SHIPPED`, `DELIVERED`, `CANCELLED` | REST (create, confirm, cancel, PATCH status) and Kafka (`payment.*`). The diagram shows the intended paths: the Kafka handlers and `PATCH status` apply their status from **any** state. |
| Payment | `PENDING`, `PROCESSING` (never persisted), `COMPLETED`, `FAILED`, `REFUNDED` | REST only |
| Shipment | `PENDING`, `PROCESSING`, `SHIPPED`, `OUT_FOR_DELIVERY`, `DELIVERED`, `RETURNED` | created by Kafka (`payment.completed`) or REST, then REST only. Any jump is allowed except out of `DELIVERED` or `RETURNED`. |
| Product | `ACTIVE`, `INACTIVE` (soft delete), `OUT_OF_STOCK` | REST. Stock reaching 0 forces `OUT_OF_STOCK`, and restocking makes it `ACTIVE` again, even after a soft delete. |
| Review | `PENDING`, `APPROVED`, `REJECTED` | create and edit set `PENDING`; moderation sets any |
| User | `ACTIVE`, `INACTIVE` (soft delete), `SUSPENDED` (never set by any code) | REST |
| Catalog entry stock | `AVAILABLE`, `LOW_STOCK`, `OUT_OF_STOCK` | derived at sync time |
