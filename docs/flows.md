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
    U->>U: validate (username 3-50 chars [a-zA-Z0-9_], email, password 10-72 bytes, not containing the username, not a common password)
    U->>DB: username and email taken? (409 if so)
    U->>DB: INSERT app_users (BCrypt hash, role CUSTOMER, status ACTIVE)
    U-->>B: 201 UserDTO
    B->>G: POST /api/v1/users/login (public)
    G->>U: forward
    U->>U: 429 with Retry-After if this username failed 5 logins in the last 15 minutes (unknown names count too)
    U->>DB: load user. The same 401 for an unknown user, an account that is not ACTIVE and a wrong password
    U->>U: sign JWT (sub=username, userId, role, exp=1h)
    U-->>B: 200 token, expiresIn=3600, username, role
    Note over B: token, username and role persisted in localStorage (auth-storage)
    B->>G: GET /api/v1/users/me + Bearer token (JWT)
    G->>G: verify signature and expiry, set X-Username etc.
    G->>U: forward with identity headers
    U->>DB: find by X-Username
    U-->>B: 200 UserDTO
```

- The SPA takes the role from the login response. It never decodes the token. It hides the admin pages from other roles, and the backend enforces the role on every admin endpoint (flow 10, [Security](security.md)).
- The lockout counter is in memory, per user-service instance. A password longer than 72 bytes is refused at registration, because BCrypt rejects anything beyond that.
- The admin account is seeded from `ADMIN_USERNAME` / `ADMIN_PASSWORD` (generated into `.env`), and it is the only way an `ADMIN` exists.
- Tokens can't be revoked. Deactivating a user (`DELETE /api/v1/users/{id}`) leaves their token valid until it expires.

## 2. Browsing and product detail

The reads on this page are public.

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant P as product-service
    participant R as review-service
    B->>G: GET /api/v1/products?page=0&size=12 (public, size at most 100)
    G->>P: forward
    P-->>B: Page of ACTIVE products
    B->>G: GET /api/v1/categories (public)
    G->>P: forward
    P-->>B: categories (at most 1000)
    B->>G: GET /api/v1/products/{id} (public)
    G->>P: forward
    P-->>B: ProductDTO. An OUT_OF_STOCK product shows, an INACTIVE (soft-deleted) one is 404 unless the caller is an admin
    B->>G: GET /api/v1/reviews/product/{id} (public, page and size at most 100, approvedOnly=true by default)
    G->>R: forward
    R-->>B: APPROVED reviews with vote counts, oldest first (approvedOnly=false is honoured for admins only)
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
    participant C as Caller (ADMIN)
    participant G as api-gateway
    participant CS as catalog-service
    participant P as product-service
    participant M as catalogdb (MongoDB)
    C->>G: POST /api/v1/catalog/sync/{productId} (ADMIN JWT, 403 for any other role)
    G->>CS: forward
    CS->>P: Feign GET /api/v1/products/{productId}
    CS->>P: Feign GET /api/v1/categories (a failure here keeps the category name already stored)
    CS->>CS: derive stockStatus (0 OUT_OF_STOCK, below 10 LOW_STOCK, else AVAILABLE)
    CS->>M: upsert catalog_entries _id=productId (optimistic lock, up to 5 attempts)
    CS-->>C: 200 CatalogEntryDTO
    C->>G: GET /api/v1/catalog/search?q=... (public)
    G->>CS: forward
    CS->>M: $text search (name 10, brand 5, description 1), regex fallback
    CS-->>C: Page of entries
```

- **Nothing triggers a sync automatically.** There is no Kafka consumer and no scheduler. A product change reaches the catalog only when an admin calls `sync` for that product, and a deleted product's entry is never removed.
- A re-sync keeps the catalog-only `featured` and `imageUrl`, but **overwrites `price`** with product-service's price, so a price set through `PATCH /api/v1/catalog/product/{id}` lasts only until the next sync.
- A product-service failure goes through the `product-service` circuit breaker and a fallback factory, and the sync answers by what it means: an unknown product is 404, no answer from product-service or an open breaker is 503, and any other bad answer (a 5xx, an undecodable body, an implausible price) is 502. A 404 does not count against the breaker.

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
    O->>O: at most 200 lines, total within NUMERIC(19,4), stockQuantity >= quantity? (400 if not)
    O->>P: Feign PATCH /internal/v1/products/{productId}/stock with delta = -quantity
    P->>P: lock the row, check, write stock. Status OUT_OF_STOCK at 0
    O->>ODB: short transaction: re-read the order, INSERT order_items (snapshot of name and price), total += price x qty
    Note over O,P: if the line cannot be saved, the reservation is released (delta = +quantity)
    O-->>B: 200 OrderDTO
```

- No database transaction is open during the two Feign calls. Two writers on one order are told apart by its version: the later one gets 409, and its reservation is released.
- `customerId` defaults to the caller's `X-Username`. A non-admin who names someone else gets 403. The SPA sends the username.
- There is no endpoint to remove a line. The SPA cancels the whole order and rebuilds it (flow 6), and every rebuild leaves a cancelled order in the history.
- Stock is reserved per line and given back by a cancel, by a declined payment (flow 5) or when the cart is abandoned: a `PENDING` order that nobody has changed for 24 hours is cancelled and its stock returned (flow 6). A logout or a second browser does not release it.
- product-service locks the product row while it changes the stock, so two concurrent reservations of the last unit run one after the other, and the second one is refused with 400.

## 5. Checkout and payment

The client orchestrates the purchase with three calls in sequence. Kafka
carries the outcome to the other services. Every event leaves its producer
through a transactional outbox ([ADR-013](adr/ADR-013-transactional-outbox.md)):
the service writes the event row in the same transaction as the state change,
and a relay publishes it about half a second after the commit. An event
therefore exists exactly when its change committed, and a Kafka outage delays
events without failing the request.

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant G as api-gateway
    participant O as order-service
    participant P as product-service
    participant PS as payment-service
    participant K as Kafka
    participant S as shipping-service
    participant N as notification-service
    B->>G: POST /api/v1/orders/{id}/confirm (JWT)
    G->>O: forward
    O->>O: must be PENDING with at least one item (400 otherwise)
    O->>O: one transaction: status CONFIRMED and an outbox row for order.placed
    O-->>B: 200 OrderDTO status CONFIRMED with totalAmount
    O->>K: the relay publishes order.placed
    K-->>N: order.placed, logged
    B->>G: POST /api/v1/payments with orderId, customerId, amount=totalAmount, method, cardLastFour (JWT)
    G->>PS: forward
    PS->>O: GET /internal/v1/orders/{id}: must be CONFIRMED, owned by the payer, total equal to the amount
    Note over PS,O: no answer from order-service means 503, a payment is never accepted blind
    PS->>PS: 409 if the order already has a COMPLETED, FAILED or REFUNDED payment, only a PENDING row is reused
    PS-->>B: 201 PaymentDTO status PENDING
    B->>G: POST /api/v1/payments/{paymentId}/process (JWT)
    G->>PS: forward
    PS->>PS: random draw, 80 percent approve
    alt approved
        PS->>PS: one transaction: status COMPLETED and an outbox row for payment.completed
        PS-->>B: 200 PaymentDTO status COMPLETED
        PS->>K: the relay publishes payment.completed
        K-->>O: order status PAID (only a CONFIRMED order, and only for the same amount)
        K-->>S: create shipment (PENDING, DHL, ETA +5 days, placeholder addresses)
        S->>K: shipment.created, through shipping-service's own outbox
        K-->>N: payment.completed and shipment.created, logged
    else declined
        PS->>PS: one transaction: status FAILED and an outbox row for payment.failed
        PS-->>B: 200 PaymentDTO status FAILED
        PS->>K: the relay publishes payment.failed
        K-->>O: order status CANCELLED, committed first, no order.cancelled
        O->>P: Feign PATCH /internal/v1/products/{productId}/stock with delta = +quantity per line
        K-->>N: payment.failed, logged
    end
    Note over B: after a decline the SPA shows Payment declined and offers to put the items into a new cart
```

What a successful purchase leaves behind:

| Service | Record | State after the flow |
|---|---|---|
| order-service | `orders` + `order_items` | `PAID`. Addresses null: the checkout form's addresses are never sent. |
| product-service | `products.stock_quantity` | reduced at add-to-cart time |
| payment-service | `payments` | `COMPLETED`, `transaction_id` set |
| shipping-service | `shipments` + one `shipment_events` row | `PENDING`. Origin `Warehouse, 123 Storage St`, destination `Customer Address`. |
| notification-service | — | three log lines (`order.placed`, `payment.completed`, `shipment.created`) |

Each producer's outbox row is deleted once Kafka has acknowledged it, so after the flow the three `outbox_event` tables are empty again.

### A declined payment

A decline is final for the order. In order:

1. `POST /api/v1/payments/{id}/process` answers **200** with `status` `FAILED`, so the caller has to read `status`. The row and the `payment.failed` outbox row commit together.
2. order-service consumes `payment.failed`, normally within a second. It commits `CANCELLED` first, then returns the stock of every line to product-service, outside any transaction. It publishes no `order.cancelled`, because `payment.failed` already said it. A replayed event finds the order `CANCELLED` and does nothing, so the stock goes back once. If product-service does not answer, the order is cancelled anyway and one WARN names the lines whose stock was not returned.
3. A retry for that order is refused with **409** and charges nothing. Until order-service has consumed the event the order still reads `CONFIRMED`, so the order check passes and payment-service refuses on its own `FAILED` row with the fixed message "The payment for this order was declined and the order is cancelled. Place a new order to try again." Once the order is `CANCELLED`, the order check answers first: `Order {id} is not awaiting payment`.
4. The SPA shows "Payment declined" and offers to put the same items into a new cart: a new order, then one add per line. Each add reserves stock again, so a line can be refused if the stock is gone meanwhile.

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant PS as payment-service
    participant K as Kafka
    participant O as order-service
    participant P as product-service
    B->>PS: POST /api/v1/payments/{id}/process
    PS-->>B: 200 PaymentDTO status FAILED (payment.failed waits in the outbox)
    alt a retry before order-service has consumed payment.failed
        B->>PS: POST /api/v1/payments for the same order
        PS->>O: GET /internal/v1/orders/{id}: still CONFIRMED, the check passes
        PS-->>B: 409 The payment for this order was declined and the order is cancelled. Place a new order to try again.
    end
    PS->>K: the relay publishes payment.failed
    K-->>O: payment.failed
    O->>O: commit status CANCELLED, no order.cancelled
    O->>P: PATCH /internal/v1/products/{id}/stock with delta = +quantity per line
    alt a retry after that
        B->>PS: POST /api/v1/payments for the same order
        PS->>O: GET /internal/v1/orders/{id}: CANCELLED
        PS-->>B: 409 Order {id} is not awaiting payment
    end
    Note over B: the SPA shows Payment declined and offers to put the items into a new cart
```

The two events of one order travel on different topics, so nothing orders them against each other. That is why the `FAILED` row is terminal instead of reusable (see [payment-service](services/payment-service.md#business-rules)).

Known gaps in this flow:

- **A payment can still arrive for an order that was cancelled meanwhile.** payment-service checks the order when the payment is created. If the customer cancels the `CONFIRMED` order before `/process` runs, `payment.completed` finds it `CANCELLED`: order-service does not apply it and logs one WARN that the payment may need a refund. Nothing refunds it automatically.
- **If `payment.failed` never reaches order-service**, for example because the record ended on the dead-letter topic, the order stays `CONFIRMED` and cannot be paid (payment-service refuses another attempt). It holds its stock until somebody cancels it. `CONFIRMED` orders do not expire.
- The order never moves past `PAID` by itself. Shipment events are not consumed by order-service (flow 8).
- If a call after `confirm` fails (the payment request times out, for example), the order stays `CONFIRMED` and holds its stock until it is paid, declined or cancelled. Confirming it again is a 400, so the client has to continue from the payment step; the SPA reads the order's status first and does. See [Frontend](frontend.md#cart-checkout-order-creation-and-payment).

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
    O->>O: 400 if CANCELLED, SHIPPED or DELIVERED, 403 for someone else's order
    O->>O: one transaction: status CANCELLED and an outbox row for order.cancelled, COMMIT
    loop each order item, after the commit and outside any transaction
        O->>P: Feign PATCH /internal/v1/products/{productId}/stock with delta = +quantity
        Note over O,P: the first no-answer from product-service ends the loop and one WARN names the lines not returned
    end
    O-->>B: 204
    O->>K: the relay publishes order.cancelled
    K-->>N: order.cancelled, logged
```

- The cancellation commits first and the stock follows, so a slow or dead product-service can neither hold a database connection nor undo the cancellation. The order is `CANCELLED` either way.
- Cancelling a **paid** order neither refunds the payment nor stops the shipment. Nothing listens to `order.cancelled` except notification-service.
- Cancelling an **already cancelled** order is a 400 (`Cannot cancel order in status: CANCELLED`) and publishes nothing, so stock goes back once. Two cancels at the same moment cannot both succeed: the later commit fails on the order's version (409) and never reaches the stock.
- A stock release that fails is not retried, and a call that timed out has an unknown outcome, so it is not repeated either. A crash between the commit and the restore leaves the stock reserved. The residual risks are listed on [order-service](services/order-service.md#known-issues-and-limitations).
- A declined payment cancels the order the same way (flow 5), except that it publishes no `order.cancelled`. An admin `PATCH /api/v1/orders/{id}/status` to `CANCELLED` runs this same code, event included.

### Abandoned carts

A cart is a `PENDING` order, and it reserves stock from the first item. `ReservationExpiryJob` in order-service cancels the carts nobody comes back to, so their stock returns to the shop.

```mermaid
sequenceDiagram
    autonumber
    participant J as ReservationExpiryJob
    participant ODB as orderdb
    participant P as product-service
    participant K as Kafka
    participant N as notification-service
    loop every 10 minutes, the first run 60 s after the start
        J->>ODB: PENDING orders with updated_at older than 24 h, idle longest first, at most 100
        loop each candidate
            J->>P: cart with lines: does product-service answer? (GET of the first line's product)
            J->>ODB: one transaction: still PENDING and still idle? status CANCELLED and an outbox row for order.cancelled
            Note over J,ODB: another replica or the customer got there first (version conflict), the cart is skipped silently
            J->>P: PATCH /internal/v1/products/{productId}/stock with delta = +quantity per line
        end
    end
    J->>K: the relay publishes order.cancelled
    K-->>N: order.cancelled, logged
```

- Only `PENDING` carts expire, after `orders.reservation.pending-ttl` (24 hours) without a change. Adding an item counts as a change. `CONFIRMED` and `PAID` orders never expire: a `payment.completed` can wait in payment-service's outbox during a Kafka outage, so age alone could cancel an order that has already been paid.
- A cart with lines is cancelled only while product-service answers, because stock that cannot be returned is lost. If it does not answer, the run stops with one WARN (at most one a minute) and the cart waits for the next run. An empty cart holds nothing and always expires.
- With several replicas, whoever commits first cancels the cart and returns its stock. The others skip it without a log line.
- A run that expired nothing writes no log line; one that did writes one INFO. `orders_reservations_expired_total` counts the carts. Existing orders got `updated_at` = the time of the migration, so the first expiry comes 24 hours after the deploy at the earliest.
- The SPA drops a cart id whose order has become `CANCELLED`, and the next Add to Cart starts a new cart.

## 7. Refund

`POST /api/v1/payments/{id}/refund` (JWT) moves a `COMPLETED` payment to
`REFUNDED` for its full amount and publishes `payment.refunded` (through
payment-service's outbox). Only notification-service consumes it: the order stays
`PAID`, the shipment carries on, and stock is untouched. The endpoint is
admin-only (403 for anyone else), and no page in the SPA calls it.

## 8. Shipping progress and tracking

```mermaid
sequenceDiagram
    autonumber
    participant A as Operator (ADMIN)
    participant V as Visitor
    participant G as api-gateway
    participant S as shipping-service
    participant K as Kafka
    participant N as notification-service
    A->>G: PATCH /api/v1/shipments/{id}/status with status, location, description (JWT)
    G->>S: forward
    S->>S: 409 unless the move is in the transition table (PENDING, PROCESSING, SHIPPED, OUT_FOR_DELIVERY, DELIVERED, and RETURNED from SHIPPED or OUT_FOR_DELIVERY)
    S->>S: update status, append shipment_events row, set actualDelivery when DELIVERED, store shipment.updated in the outbox (one transaction)
    S-->>A: 200 ShipmentDTO
    S->>K: the relay publishes shipment.updated
    K-->>N: shipment.updated, logged
    V->>G: GET /api/v1/shipments/tracking/{trackingNumber} (public)
    G->>S: forward
    S-->>V: tracking number, status, carrier, estimated delivery and events only (no order id, customer or addresses)
    V->>G: GET /api/v1/shipments/{id}/history (JWT required)
    G-->>V: 401 for an anonymous visitor. The SPA then redirects to login
```

- Nothing advances a shipment automatically: no scheduler, no carrier integration, and no page in the SPA. Statuses change only through this PATCH.
- order-service never hears about shipment progress, so orders stay `PAID`. `SHIPPED` and `DELIVERED` are reachable only through `PATCH /api/v1/orders/{id}/status`, which is admin-only and follows the transition table (`PAID` to `SHIPPED` to `DELIVERED`; any other move is 409). It publishes nothing for those two statuses.

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
    Note over R,P: a 404 stays 404, no answer or an open breaker is 503, any other bad answer is 502
    R->>R: one review per (product, X-Username), 409 otherwise
    R-->>B: 201 ReviewDTO status PENDING
    B->>G: PATCH /api/v1/reviews/{id}/moderate?status=APPROVED (ADMIN JWT)
    G->>R: forward
    R-->>B: 200 for ADMIN, 403 for any other caller
    B->>G: POST /api/v1/reviews/{id}/vote with helpful true or false (JWT)
    G->>R: forward
    R-->>B: 200 (one vote per user, re-voting flips it), 403 on your own review, 404 on a review that is not APPROVED
```

- Editing a review (`PUT`, author only) sends it back to `PENDING`. Deleting is allowed for the author or a caller with `X-User-Role: ADMIN`.
- The product page loads approved reviews only, so authors don't see their own pending review there. Submitting again returns 409. Unapproved reviews are readable only by their author (`GET /api/v1/reviews/customer/{username}` or `GET /api/v1/reviews/{id}`) and by admins.
- There is no verified-purchase check. review-service never asks order-service whether the author bought the product.

## 10. Administration

The SPA's admin area (`/admin/**`) manages products, categories, orders and
reviews. The backend enforces the role on the endpoints it uses: product and
category writes, `PATCH /api/v1/orders/{id}/status`, review moderation, catalog
writes, shipment creation and status changes, and refunds need the exact role
`ADMIN` (403 for any other caller, 401 without an identity). Hiding the admin
pages in the SPA is a convenience, not the control. Some admin screens also
have no backing endpoint (listing all orders, listing pending reviews). See
[Frontend: admin flows](frontend.md#admin-flows), [Security](security.md) and
[Findings](findings.md).

## Status models side by side

```mermaid
stateDiagram-v2
    state "Order (order-service)" as Order {
        [*] --> PENDING
        PENDING --> CONFIRMED: confirm
        CONFIRMED --> PAID: payment.completed
        CONFIRMED --> CANCELLED: payment.failed or DELETE
        PENDING --> CANCELLED: DELETE or idle for 24 h
        PAID --> CANCELLED: DELETE
        PAID --> SHIPPED: PATCH status
        SHIPPED --> DELIVERED: PATCH status
    }
```

| Entity | Statuses | Changed by |
|---|---|---|
| Order | `PENDING`, `CONFIRMED`, `PAID`, `SHIPPED`, `DELIVERED`, `CANCELLED` | REST (create, confirm, cancel, PATCH status), Kafka (`payment.*`) and the abandoned-cart job. Every change is checked against the current status: the Kafka handlers apply only the moves in the diagram (a late event for another status is ignored), and `PATCH status` is admin-only and follows the transition table (409 otherwise). |
| Payment | `PENDING`, `PROCESSING` (never committed), `COMPLETED`, `FAILED`, `REFUNDED` | REST only. `FAILED` is final: a new payment for the order is refused (409). |
| Shipment | `PENDING`, `PROCESSING`, `SHIPPED`, `OUT_FOR_DELIVERY`, `DELIVERED`, `RETURNED` | created by Kafka (`payment.completed`) or REST, then REST only (admin). Moves follow a transition table: `PENDING`, `PROCESSING`, `SHIPPED`, `OUT_FOR_DELIVERY`, `DELIVERED`, and `RETURNED` from `SHIPPED` or `OUT_FOR_DELIVERY`; `DELIVERED` and `RETURNED` are final (409 otherwise). |
| Product | `ACTIVE`, `INACTIVE` (soft delete), `OUT_OF_STOCK` | REST. Stock reaching 0 forces `OUT_OF_STOCK`, and restocking makes it `ACTIVE` again, even after a soft delete. |
| Review | `PENDING`, `APPROVED`, `REJECTED` | create and edit set `PENDING`; moderation sets any |
| User | `ACTIVE`, `INACTIVE` (soft delete), `SUSPENDED` (never set by any code) | REST |
| Catalog entry stock | `AVAILABLE`, `LOW_STOCK`, `OUT_OF_STOCK` | derived at sync time |
