# ADR-006: Synchronous calls for lookups and stock, Kafka events for state changes

- **Status:** Accepted. The compensation side was never built; see Consequences.
- **Recorded:** 2026-10-29, reconstructed from the code.

## Context

A purchase touches five services: product (stock), order, payment, shipping
and notification. Some interactions need an answer before the user's action
can complete. Does this product exist, what does it cost, is there stock? Others
only need to happen eventually, and their producer shouldn't care who reacts.
For example: a payment went through, so ship it and tell the customer.

## Decision

- **Synchronous Feign calls**, all of them to product-service, only where the caller can't proceed without the answer:
  - order-service reads the product (name, price, stock) when a line is added, and reserves stock with `PATCH /stock {"delta": -n}`;
  - review-service checks that a product exists before accepting a review;
  - catalog-service pulls a product snapshot when asked to sync.
- **Asynchronous Kafka events** for every business state change another service might react to: `order.placed`, `order.cancelled`, `payment.completed`, `payment.failed`, `payment.refunded`, `shipment.created`, `shipment.updated`. Producers don't know their consumers.
- **The purchase is choreographed.** The client drives the first steps over REST: confirm the order, create the payment, process it. From the payment result onwards, services react to events. order-service marks the order paid or cancelled, shipping-service creates a shipment, and notification-service informs the customer. No orchestrator holds the state of a purchase.

## Consequences

Positive:
- Adding a reaction costs nothing upstream. notification-service subscribes to seven topics without any producer changing.
- A slow or failed downstream reaction (notification, shipping) doesn't slow down or fail the checkout.
- Only one service, product-service, sits on synchronous critical paths.

Negative:
- **No compensations were built.** A declined payment cancels the order but never releases the reserved stock. Refunds and order cancellations don't reach shipping, and shipment progress never reaches the order. The [flows](../flows.md) show each case.
- **The client is part of the saga.** Payments start from the browser with a client-supplied amount, and nothing on the server checks it against the order. The order-service consumer then accepts any `payment.completed`, whatever the order's state.
- **Dual writes.** Each producer writes its database and sends to Kafka in the same method, with no transactional outbox, so a crash between the two leaves them disagreeing.
- No single place shows where a purchase stands. Following one means correlating by order ID across four services' logs and tables.
- product-service is a shared dependency. Its outage blocks adding items, reviewing and syncing. Mitigations: connect-failure retries everywhere, and a circuit breaker in order-service only.

## Related

[Communication](../communication.md) · [Event catalog](../events.md) · [End-to-end flows](../flows.md) · [ADR-007](ADR-007-json-events-mirrored-classes.md)
