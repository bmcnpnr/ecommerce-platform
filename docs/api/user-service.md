# User service API reference

Base URL through the gateway `http://localhost:8080`; direct (bypasses the gateway, dev only) `http://localhost:8081`.

- **Try it:** the platform Swagger UI at `http://localhost:8080/swagger-ui.html` opens on `user-service`. Run `POST /api/v1/users/login`, click **Authorize**, paste the `token`, and every other service's entry reuses it. Calls go through the gateway, which overwrites `X-Username` from the token. The form still asks for that header on `/me` because the parameter is declared, so type anything.
- **OpenAPI document:** `http://localhost:8080/api-docs/user-service` (through the gateway), `http://localhost:8081/api-docs` (direct), or the committed snapshot [openapi/user-service.json](openapi/user-service.json). It attaches the `bearerAuth` scheme to every operation, the public ones included (`config/OpenApiConfig.java`).
- Opening the service's own Swagger UI at `http://localhost:8081/swagger-ui.html` calls the service directly. The bearer token is then ignored, and `X-Username` is whatever you type.

Service overview: [user-service](../services/user-service.md).

## Conventions

**Content type.** Request bodies are JSON and must be sent with `Content-Type: application/json`. A `POST` or `PUT` body sent with another content type, or without one, fails with 415 (see the error table). Responses are `application/json`; `DELETE` returns no body.

**Authentication.** The gateway verifies the token; user-service checks ownership and role from the identity headers.

- Public at the gateway (no token): `POST /register`, `POST /login`.
- Every other endpoint needs `Authorization: Bearer <JWT>`. A missing, malformed, badly signed or expired token is answered by the gateway with 401 and an empty body; the request never reaches user-service.
- On authenticated requests the gateway sets `X-Username` (JWT `sub`), `X-User-Id` (`userId` claim) and `X-User-Role` (`role` claim), overwriting anything the client sent. `GET /me` uses `X-Username`; `/{id}` endpoints compare the path id with `X-User-Id` (owner) or accept `X-User-Role` exactly `ADMIN`.
- Missing identity is 401 and someone else's id is 403 `Access denied`. A 401 with a JSON body from user-service is a failed login or missing identity.
- Responses carry `X-Content-Type-Options: nosniff` and `Cache-Control: no-store`.

**Correlation id.** Send `X-Correlation-Id` to choose the id (it must match `^[A-Za-z0-9._-]{1,64}$`); otherwise the service generates a UUID. It is always returned in the `X-Correlation-Id` response header and in error bodies as `correlationId`.

**JSON.** Boot 4 uses Jackson 3 with its defaults (the service sets no `spring.jackson.*`):

- properties are written in alphabetical order;
- null fields are written as `null`, not omitted;
- unknown request properties are ignored (so `"role": "ADMIN"` in a registration body has no effect);
- `LocalDateTime` is an ISO-8601 local date-time string without offset, for example `"2026-10-29T18:07:12.123456"`. The number of fraction digits varies. The value is in the JVM's default time zone.

Ids are JSON integers (Java `Long`); enums are strings. Nothing is paginated.

**Errors.** Every error produced by user-service has this body (`exception/ErrorResponse.java`):

```json
{
  "correlationId": "5f0c8c7e-2d0a-4c5e-9a53-0f5f3b1f2a9d",
  "error": "Conflict",
  "fieldErrors": null,
  "message": "Username already taken: alice",
  "path": "/api/v1/users/register",
  "status": 409,
  "timestamp": "2026-10-29T18:07:12.123456"
}
```

`path` is the request URI as user-service received it, which is the gateway path (no rewriting). `fieldErrors` is non-null only for Bean Validation failures. Mapping in `exception/GlobalExceptionHandler.java`:

| Exception | Status | `error` | `message` | When |
|---|---|---|---|---|
| `MethodArgumentNotValidException` | 400 | `Bad Request` | `Validation failed`, with `fieldErrors` | A `@Valid` body breaks a constraint |
| `HttpMessageNotReadableException` | 400 | `Bad Request` | `Malformed request body` | Malformed JSON, or no body |
| `MethodArgumentTypeMismatchException` | 400 | `Bad Request` | `Invalid value for parameter '<name>'` | Non-numeric `{id}` |
| `ServletRequestBindingException`, `MissingServletRequestParameterException` | 400 | `Bad Request` | `Missing or invalid request parameter` | Missing required header or parameter |
| `InvalidCredentialsException` | 401 | `Unauthorized` | `Invalid username or password` | Login, whatever the reason |
| missing identity | 401 | `Unauthorized` | `Authentication required` | `/me` or `/{id}` without `X-Username` / `X-User-Id` |
| `ForbiddenException` | 403 | `Forbidden` | `Access denied` | `/{id}` of another user, caller not `ADMIN` |
| `UserNotFoundException` | 404 | `Not Found` | `User not found with id: <id>` or `User not found: <username>` | Unknown id or username; an unmapped path gives `Resource not found` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | `Method not allowed` | Wrong verb on a mapped path |
| not acceptable | 406 | `Not Acceptable` | `Not acceptable` | Unsupported `Accept` |
| `UserAlreadyExistsException` | 409 | `Conflict` | `Username already taken: <username>` or `Email already registered: <email>`; `Resource already exists or violates a constraint` for a race | Registration |
| unsupported media type | 415 | `Unsupported Media Type` | `Unsupported media type` | Wrong or missing `Content-Type` |
| `TooManyLoginAttemptsException` | 429 | `Too Many Requests` | `Too many failed login attempts. Try again later.` | Login lockout; `Retry-After` header in seconds |
| Anything else | 500 | `Internal Server Error` | `An unexpected error occurred` | Logged at ERROR with the stack trace. |

Field error messages are the ones declared on the DTOs. Constraints declared without a message use Hibernate Validator's default English text, for example `size must be between 0 and 100`. Several messages can be reported for one field, and the order of `fieldErrors` is not guaranteed.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/users/register` | Public | Bean Validation; unique username and email | Create a `CUSTOMER` account |
| POST | `/api/v1/users/login` | Public | Bean Validation; account status; password | Issue a JWT |
| GET | `/api/v1/users/me` | Bearer JWT | none; user resolved from `X-Username` | The caller's profile |
| GET | `/api/v1/users/{id}` | Bearer JWT | owner (`X-User-Id`) or `ADMIN` | A user's profile by id |
| PUT | `/api/v1/users/{id}` | Bearer JWT | owner or `ADMIN`; Bean Validation | Partial update of a user's profile |
| DELETE | `/api/v1/users/{id}` | Bearer JWT | owner or `ADMIN` | Soft-delete a user |

## POST /api/v1/users/register

Creates an account with role `CUSTOMER` and status `ACTIVE`. Used by the frontend's register page, which then sends the user to the login page; registration does not log the user in.

**Auth:** Public. No service-side checks beyond validation, the password policy and uniqueness.

**Request body** `RegisterRequest`

| Field | Type | Required | Validation (message) | Notes |
|---|---|---|---|---|
| `username` | string | yes | `@NotBlank` (`Username is required`); `@Size(min = 3, max = 50)` (`Username must be between 3 and 50 characters`); `@Pattern("^[a-zA-Z0-9_]+$")` (`Username can only contain letters, digits, and underscores`) | Unique, case-sensitive. Becomes the JWT `sub` and the platform-wide user name. Cannot be changed later. |
| `email` | string | yes | `@NotBlank` (`Email is required`); `@Email` (`Invalid email format`); `@Size(max = 100)` (`size must be between 0 and 100`) | Unique, case-sensitive. Cannot be changed later. |
| `password` | string | yes | `@NotBlank` (`Password is required`); `@PasswordPolicy` | 10 to 72 UTF-8 bytes (`Password must be between 10 and 72 bytes long`), must not contain the username (`Password must not contain the username`), must not be a common password (`Password is too common`); all 400 on field `password`. Stored as a BCrypt hash (cost 10). |
| `firstName` | string | no | `@Size(max = 50)` (`size must be between 0 and 50`) | |
| `lastName` | string | no | `@Size(max = 50)` (`size must be between 0 and 50`) | |
| `phoneNumber` | string | no | `@Size(max = 20)` (`size must be between 0 and 20`) | No format check |

Any other property, `role` included, is ignored. The default addresses cannot be set here; use `PUT /{id}`.

```json
{
  "username": "alice",
  "email": "alice@example.com",
  "password": "alice-password-1",
  "firstName": "Alice",
  "lastName": "Example"
}
```

**Responses**

`201 Created` with a [`UserDTO`](#userdto). No `Location` header.

```json
{
  "createdAt": "2026-10-29T18:07:12.123456",
  "defaultBillingAddress": null,
  "defaultShippingAddress": null,
  "email": "alice@example.com",
  "firstName": "Alice",
  "id": 42,
  "lastName": "Example",
  "phoneNumber": null,
  "role": "CUSTOMER",
  "status": "ACTIVE",
  "username": "alice"
}
```

- `400` validation failure or malformed JSON. For `{"username":"x","email":"not-an-email","password":"1"}`:

  ```json
  {
    "correlationId": "0b1e3f9a-6c1d-4a8e-b0f2-9d4e5c6a7b8c",
    "error": "Bad Request",
    "fieldErrors": [
      { "field": "username", "message": "Username must be between 3 and 50 characters" },
      { "field": "email", "message": "Invalid email format" },
      { "field": "password", "message": "Password must be between 10 and 72 bytes long" }
    ],
    "message": "Validation failed",
    "path": "/api/v1/users/register",
    "status": 400,
    "timestamp": "2026-10-29T18:07:12.123456"
  }
  ```

- `409` `Username already taken: <username>`. The username is checked first, so a request that duplicates both gets this message.
- `409` `Email already registered: <email>`.
- `409` `Resource already exists or violates a constraint` when two identical registrations race past the uniqueness check.
- `415` when the content type is not JSON.

**Side effects:** one `INSERT` into `app_users`. No events, no other calls.

**Example**

```bash
curl -s -X POST http://localhost:8080/api/v1/users/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","email":"alice@example.com","password":"alice-password-1","firstName":"Alice","lastName":"Example"}'
```

## POST /api/v1/users/login

Checks the credentials and issues a JWT signed with `jwt.secret`. The frontend stores `token`, `username`, `role` and `expiresIn` and sends the token on every later call.

**Auth:** Public. Service-side: account status and password.

**Request body** `LoginRequest`

| Field | Type | Required | Validation (message) | Notes |
|---|---|---|---|---|
| `username` | string | yes | `@NotBlank` (`Username is required`) | Exact, case-sensitive match |
| `password` | string | yes | `@NotBlank` (`Password is required`) | |

```json
{ "username": "alice", "password": "alice-password-1" }
```

**Responses**

`200 OK` with an [`AuthResponse`](#authresponse):

```json
{
  "expiresIn": 3600,
  "role": "CUSTOMER",
  "token": "eyJhbGciOiJIUzM4NCJ9.eyJzdWIiOiJhbGljZSIsInVzZXJJZCI6NDIsInJvbGUiOiJDVVNUT01FUiIsImlhdCI6MTc5MzI5NjgwMCwiZXhwIjoxNzkzMzAwNDAwfQ.<signature>",
  "username": "alice"
}
```

The response does not contain the user's id; read it from `GET /me` or from the token's `userId` claim.

The checks run in this order (`UserService.login()`):

1. A username locked out by earlier failures: `429` with `Retry-After`.
2. Unknown username, wrong password, `INACTIVE` or `SUSPENDED` account: the same `401` `Invalid username or password`. Unknown users still pay a BCrypt comparison.

Also `400` when a field is blank or the JSON is malformed. 5 failed logins for a username within 15 minutes lock it (unknown usernames count too); the state is in memory, per instance.

**Side effects:** none. Login is a read-only transaction; nothing records the login.

**Example**

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/users/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice","password":"alice-password-1"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
```

## GET /api/v1/users/me

Returns the profile of the user named by `X-Username`. Through the gateway that is always the token's `sub`. The frontend uses it on the profile page and to pre-fill the checkout addresses.

**Auth:** Bearer JWT at the gateway; the service answers 401 `Authentication required` without `X-Username`. The user is resolved from the header.

**Headers**

| Name | In | Type | Required | Notes |
|---|---|---|---|---|
| `X-Username` | header | string | yes | Set by the gateway from the JWT `sub`, overwriting any client value. On a direct call to port 8081 whoever calls chooses it. |

**Responses**

- `200 OK` with a [`UserDTO`](#userdto), whatever the account's status.
- `401` from the gateway, empty body: no valid token.
- `404` `User not found: <username>`: the token names a user that no longer exists (for example after the database was reset).
- `401` `Authentication required`: header absent, which only happens on direct calls.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/users/me -H "Authorization: Bearer $TOKEN"
```

## GET /api/v1/users/{id}

Returns the profile with the given id.

**Auth:** Bearer JWT at the gateway. Owner (`X-User-Id` equals `{id}`) or `ADMIN`; otherwise 403 `Access denied`. The frontend's API client defines this call but no page uses it.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (int64) | yes | Must parse as a `Long`, otherwise 400 |

**Responses**

- `200 OK` with a [`UserDTO`](#userdto), whatever the account's status.
- `400` non-numeric id.
- `401` from the gateway, empty body; `Authentication required` from the service when the identity header is missing.
- `403` `Access denied`: another user's id, caller not `ADMIN`.
- `404` `User not found with id: <id>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/users/42 -H "Authorization: Bearer $TOKEN"
```

## PUT /api/v1/users/{id}

Partial profile update despite the verb. Each field that is present and non-null replaces the stored value; absent or `null` fields are left unchanged, so a field cannot be cleared back to null (an empty string is accepted). The frontend's profile page calls it with the id it got from `GET /me`.

**Auth:** Bearer JWT at the gateway. Owner or `ADMIN`; otherwise 403 `Access denied`.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (int64) | yes | Must parse as a `Long` |

**Request body** `UpdateUserRequest`

| Field | Type | Required | Validation (message) | Notes |
|---|---|---|---|---|
| `firstName` | string | no | `@Size(max = 50)` (`size must be between 0 and 50`) | |
| `lastName` | string | no | `@Size(max = 50)` (`size must be between 0 and 50`) | |
| `phoneNumber` | string | no | `@Size(max = 20)` (`size must be between 0 and 20`) | No format check |
| `defaultShippingAddress` | string | no | none | Free text, stored as `TEXT` |
| `defaultBillingAddress` | string | no | none | Free text, stored as `TEXT` |

Username, email, password, role and status are not part of the body and cannot be changed; if sent, they are ignored.

```json
{
  "phoneNumber": "+90 555 000 0000",
  "defaultShippingAddress": "Example St. 1, Istanbul",
  "defaultBillingAddress": "Example St. 1, Istanbul"
}
```

**Responses**

- `200 OK` with the updated [`UserDTO`](#userdto).
- `400` validation failure, malformed JSON or non-numeric id.
- `401` from the gateway, empty body.
- `403` `Access denied`.
- `404` `User not found with id: <id>`.

**Side effects:** `UPDATE app_users` of the changed columns and `updated_at`. No events.

**Example**

```bash
curl -s -X PUT http://localhost:8080/api/v1/users/42 \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"defaultShippingAddress":"Example St. 1, Istanbul"}'
```

## DELETE /api/v1/users/{id}

Soft delete: sets the status to `INACTIVE` and keeps the row. Afterwards login answers 401 `Account is inactive`; the username and email stay taken; reads still return the user. Tokens already issued stay valid until they expire (up to one hour). Nothing can reactivate the account. The frontend's API client defines this call but no page uses it.

**Auth:** Bearer JWT at the gateway. Owner or `ADMIN`; otherwise 403 `Access denied`.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (int64) | yes | Must parse as a `Long` |

**Responses**

- `204 No Content`, also when the user is already inactive.
- `400` non-numeric id.
- `401` from the gateway, empty body.
- `403` `Access denied`.
- `404` `User not found with id: <id>`.

**Side effects:** `UPDATE app_users SET status = 'INACTIVE', updated_at = now`. No events.

**Example**

```bash
curl -i -X DELETE http://localhost:8080/api/v1/users/42 -H "Authorization: Bearer $TOKEN"
```

## Operational endpoints

Served on port 8081 only. The gateway does not route these paths to user-service. No authentication, except `serviceregistry`, which answers 403 to non-loopback callers.

| Method | Path | Purpose |
|---|---|---|
| GET | `/actuator/health` | Aggregate health, status only (`show-details: never`). Kubernetes also gets `/actuator/health/liveness` and `/actuator/health/readiness`. |
| GET | `/actuator/info`, `/actuator/metrics`, `/actuator/prometheus` | Info, metrics, Prometheus scrape |
| GET, POST | `/actuator/serviceregistry` | Read or set the Eureka status, loopback only. The Kubernetes `preStop` hook POSTs `{"status":"OUT_OF_SERVICE"}` before shutdown. |
| GET | `/api-docs`, `/swagger-ui.html` | OpenAPI document and Swagger UI |

## Schemas

### UserDTO

`dto/UserDTO.java`, built by `UserService.toDTO()`. Returned by register, `/me`, `/{id}` and `PUT /{id}`. The password hash and `updatedAt` are never exposed.

| Field | JSON type | Nullable | Notes |
|---|---|---|---|
| `createdAt` | string (ISO-8601 local date-time) | no | Account creation time |
| `defaultBillingAddress` | string | yes | |
| `defaultShippingAddress` | string | yes | |
| `email` | string | no | |
| `firstName` | string | yes | |
| `id` | integer (int64) | no | `app_users.id`, the same value as the JWT `userId` claim |
| `lastName` | string | yes | |
| `phoneNumber` | string | yes | |
| `role` | string | no | `CUSTOMER` or `ADMIN` |
| `status` | string | no | `ACTIVE`, `INACTIVE` or `SUSPENDED` |
| `username` | string | no | |

### AuthResponse

`dto/AuthResponse.java`. Returned by login.

| Field | JSON type | Notes |
|---|---|---|
| `expiresIn` | integer | Token lifetime in seconds: `jwt.expiration-ms / 1000`, so 3600 |
| `role` | string | `CUSTOMER` or `ADMIN`, the same as the token's `role` claim |
| `token` | string | Compact JWS, see below |
| `username` | string | |

### JWT

Built by `JwtService.generateToken()` with JJWT 0.12.6 and signed with HMAC-SHA over `jwt.secret` (env `JWT_SECRET`). The gateway verifies it with the same secret, so the two must be byte-identical.

| Part | Name | JSON type | Value |
|---|---|---|---|
| header | `alg` | string | Chosen from the secret's length: `HS512`, because the secret must be at least 64 bytes. |
| payload | `sub` | string | Username. The gateway forwards it as `X-Username`. |
| payload | `userId` | integer | User id. The gateway forwards it as `X-User-Id`. |
| payload | `role` | string | `CUSTOMER` or `ADMIN`. The gateway forwards it as `X-User-Role`. |
| payload | `iat` | integer | Issued at, seconds since the epoch |
| payload | `exp` | integer | `iat` + 3600 |

No other claims or header parameters. The token cannot be refreshed or revoked; log in again after it expires.

### ErrorResponse

`exception/ErrorResponse.java`. Errors produced by user-service; the gateway's own 401s have no body.

| Field | JSON type | Nullable | Notes |
|---|---|---|---|
| `correlationId` | string | no | Same value as the `X-Correlation-Id` response header |
| `error` | string | no | Reason phrase, for example `Not Found` |
| `fieldErrors` | array of `FieldError` | yes | Only on validation failures |
| `message` | string | no | See the error table |
| `path` | string | no | Request URI |
| `status` | integer | no | HTTP status code |
| `timestamp` | string (ISO-8601 local date-time) | no | When the error was produced |

### FieldError

`ErrorResponse.FieldError`.

| Field | JSON type | Notes |
|---|---|---|
| `field` | string | DTO field name, for example `password` |
| `message` | string | Constraint message |
