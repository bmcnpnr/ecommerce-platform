# ADR-004: Authenticate at the gateway, pass identity as headers

- **Status:** Accepted. The authorization half is incomplete; see Consequences.
- **Recorded:** 2026-10-29, reconstructed from the code.

## Context

Every service needs to know who is calling, but making each service validate
tokens means duplicating key handling, JWT libraries and security
configuration across eight codebases.

## Decision

- **user-service issues** HMAC-signed JWTs at login, with subject = username, a numeric `userId` claim and a `role` claim, valid for one hour.
- **The gateway validates** every token on non-public routes with the same shared secret (`JWT_SECRET`). It rejects bad tokens with 401, then forwards the request with `X-Username`, `X-User-Id` and `X-User-Role` headers.
- **Services trust those headers** and never see or parse the token. A short list of read-only and auth paths is public at the gateway.
- The header vocabulary is a cross-service contract, pinned by Pact tests between the gateway and the services that read it.

## Consequences

Positive:
- One place validates tokens. Services stay free of security dependencies (user-service's Spring Security permits all requests).
- The format of the identity is fixed and tested end to end.

Negative:
- **The trust boundary is the network.** Anything that reaches a service directly can claim any identity by setting the headers itself. Compose publishes every service port (8081–8088) on the host, so on a developer machine the boundary is only a convention.
- **Authentication without authorization.** The gateway checks *who* you are, never *what you may do*. Only review-service reads the role (for deleting reviews), and only review-service and user-service read the identity at all. Product, catalog, order, payment and shipping endpoints accept any valid token for any resource, including admin-style writes and other customers' orders. See [Security](../security.md) and [Findings](../findings.md).
- Rotating the secret means restarting the issuer and the gateway together, and every token in flight is invalidated.
- Token revocation isn't possible before expiry, and there are no refresh tokens.

## Related

[Security](../security.md) · [api-gateway](../services/api-gateway.md) · [user-service](../services/user-service.md)
