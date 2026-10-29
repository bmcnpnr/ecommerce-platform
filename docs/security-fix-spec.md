# Security fix spec (2026-10-29)

Shared rules for fixing the findings in [findings.md](findings.md#security-test-findings-2026-10-29).
Every service applies them the same way, so the platform has one authorization model.

## Identity

- The gateway verifies the JWT, strips client copies of the identity headers and sets
  `X-Username`, `X-User-Id` and `X-User-Role`. Services treat these headers as authoritative.
- Roles are exactly `ADMIN` or `CUSTOMER`. Compare case-sensitively, with no trimming:
  `admin`, `Admin`, `" ADMIN"`, `ROLE_ADMIN` are **not** admin.
- The ownership key is the username: `customerId` in order, payment, shipping and review is
  compared with `X-Username`. user-service compares `/users/{id}` with `X-User-Id`.

## Endpoint classes

| Class | Rule | Failure |
|---|---|---|
| public | anonymous allowed (exactly the gateway's public list: GET products, categories, catalog, `GET /reviews/product/**`, `GET /shipments/tracking/**`, register, login) | — |
| authenticated | non-blank `X-Username` | 401 |
| admin | `X-User-Role` is exactly `ADMIN` | 401 without identity, else 403 |
| owner-or-admin | `X-Username` equals the resource owner, or admin | 401 without identity, else 403 |
| internal | path under `/internal/v1/**`; the gateway never routes it (404 at the edge); no identity needed | — |

401 and 403 use the service's existing error-body shape with generic messages
(`Authentication required`, `Access denied`). Check authorization **before** the service
layer does any work. For a resource that exists but belongs to someone else, return 403
(not 404).

Where a request carries an owner (for example `customerId` in a query or body), a
non-admin caller may only name themselves (otherwise 403). Default it to `X-Username`
when it is omitted.

## Internal endpoints

| Provider | Endpoint | Caller |
|---|---|---|
| product-service | `PATCH /internal/v1/products/{id}/stock`, same body and response as the public stock endpoint, which becomes admin-only | order-service `ProductServiceClient` |
| order-service | `GET /internal/v1/orders/{id}`, returns the existing `OrderDTO` | payment-service (new Feign client, I-1) |

## Hardening every service applies

1. **Client errors are 4xx, never 500**: unknown path → 404 (`NoResourceFoundException`),
   wrong `Content-Type` → 415, unacceptable `Accept` → 406, malformed or unreadable body → 400,
   unknown sort property → 400, page or size out of range → 400 (max page size 100 unless the
   service already caps lower), NUL bytes or over-long strings → 400 (validate the field length
   against the column with `@Size` before it reaches the database), unique-constraint races → 409.
2. **Error bodies leak nothing**: no Java type names, parser text, SQL, internal URLs, Feign
   client names or downstream bodies. Use fixed messages per error kind (for example
   `Malformed request body`, `Invalid value for parameter 'id'`). Field validation messages
   stay.
3. **Response headers**: a filter adds `X-Content-Type-Options: nosniff` and
   `Cache-Control: no-store` to every `/api/**` and `/internal/**` response.
4. **Correlation id**: accept an incoming `X-Correlation-Id` only if it matches
   `^[A-Za-z0-9._-]{1,64}$`; otherwise generate a new UUID. Never echo or log the rejected value.
5. **Actuator (S-6)**: keep `serviceregistry` exposed (the Kubernetes `preStop` hook calls it on
   `localhost` for hitless rollouts), but a filter answers 403 to any `/actuator/serviceregistry`
   request whose remote address isn't loopback. Set `management.endpoint.health.show-details: never`.
6. **Logs**: never log raw user input that can contain CR/LF; strip control characters and cap
   at 256 characters.

## Tests

- Fixing a pinned hole means removing its `@Disabled("BUG ...")` marker; the test must then pass.
- If a pre-existing test exercised the insecure behaviour (for example calling an admin endpoint
  without headers), update it to send the right identity. Never weaken a security test. If a
  pinned test's expectation is wrong or conflicts with this spec, change it minimally and say why.
- Pact provider tests must keep passing. The frontend pacts' tokens decode to `alice` (42) and
  `bob` (43), both `CUSTOMER`, and `admin` (1, `ADMIN`); adjust provider states so the data
  belongs to the right user rather than editing the frontend pact files.
- Flyway migrations must be safe on existing data (deduplicate before adding a unique constraint).

## Handled centrally, not per service

JWT secret and admin bootstrap plumbing in compose and k8s, the gateway, Eureka authentication
(S-10), nginx headers (S-7), network exposure (S-5) and Grafana (S-18).
