# User service API reference

Base URL through the gateway `http://localhost:8080`; direct (bypasses the gateway, dev only) `http://localhost:8081`.

- **Try it:** the platform Swagger UI at `http://localhost:8080/swagger-ui.html` opens on `user-service`. Run `POST /api/v1/users/login`, click **Authorize**, paste the `token`, and every other service's entry reuses it. Calls go through the gateway, which overwrites `X-Username` from the token. The form still asks for that header on `/me` because the parameter is declared, so type anything.
- **OpenAPI document:** `http://localhost:8080/api-docs/user-service` (through the gateway), `http://localhost:8081/api-docs` (direct), or the committed snapshot [openapi/user-service.json](openapi/user-service.json). It attaches the `bearerAuth` scheme to every operation, the public ones included (`config/OpenApiConfig.java`).
- Opening the service's own Swagger UI at `http://localhost:8081/swagger-ui.html` calls the service directly. The bearer token is then ignored, and `X-Username` is whatever you type.

Service overview: [user-service](../services/user-service.md).

## Conventions

**Content type.** Request bodies are JSON and must be sent with `Content-Type: application/json`. A `POST` or `PUT` body sent with another content type, or without one, fails with 500 (see the error table). Responses are `application/json`; `DELETE` returns no body.

**Authentication.** The gateway does it; user-service checks nothing.

- Public at the gateway (no token): `POST /register`, `POST /login`, `GET /internal/{username}`.
- Every other endpoint needs `Authorization: Bearer <JWT>`. A missing, malformed, badly signed or expired token is answered by the gateway with 401 and an empty body; the request never reaches user-service.
- On authenticated requests the gateway sets `X-Username` (JWT `sub`), `X-User-Id` (`userId` claim) and `X-User-Role` (`role` claim), overwriting anything the client sent. user-service reads only `X-Username`, and only on `GET /me`.
- No endpoint checks role or ownership. A 401 from user-service itself (with a JSON body) only ever means failed login.

**Correlation id.** Send `X-Correlation-Id` to choose the id; otherwise the service generates a UUID. It is always returned in the `X-Correlation-Id` response header and in error bodies as `correlationId`.

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
| `HttpMessageNotReadableException` | 400 | `Bad Request` | The framework's message | Malformed JSON, or no body. For a missing body the message names the controller method, for example `Required request body is missing: public org.springframework.http.ResponseEntity<com.ecommerce.user.dto.UserDTO> com.ecommerce.user.controller.UserController.register(com.ecommerce.user.dto.RegisterRequest)` |
| `MethodArgumentTypeMismatchException` | 400 | `Bad Request` | The framework's message, naming the parameter and the Java types | Non-numeric `{id}` |
| `ServletRequestBindingException` (includes `MissingRequestHeaderException`), `MissingServletRequestParameterException` | 400 | `Bad Request` | For example `Required request header 'X-Username' for method parameter type String is not present` | `GET /me` without `X-Username`; only possible on direct calls |
| `InvalidCredentialsException` | 401 | `Unauthorized` | `Invalid username or password`, `Account is inactive` or `Account is suspended` | Login |
| `UserNotFoundException` | 404 | `Not Found` | `User not found with id: <id>` or `User not found: <username>` | Unknown id or username |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | For example `Request method 'PATCH' is not supported` | Wrong verb on a mapped path |
| `UserAlreadyExistsException` | 409 | `Conflict` | `Username already taken: <username>` or `Email already registered: <email>` | Registration |
| Anything else | 500 | `Internal Server Error` | `An unexpected error occurred` | Includes a wrong or missing `Content-Type` (`HttpMediaTypeNotSupportedException`), a GET on an unmapped path such as `/api/v1/users` (`NoResourceFoundException`), a concurrent duplicate registration (`DataIntegrityViolationException`) and a password over 72 bytes (`IllegalArgumentException` from BCrypt). Logged at ERROR with the stack trace. |

Field error messages are the ones declared on the DTOs. Constraints declared without a message use Hibernate Validator's default English text, for example `size must be between 0 and 100`. Several messages can be reported for one field, and the order of `fieldErrors` is not guaranteed.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| POST | `/api/v1/users/register` | Public | Bean Validation; unique username and email | Create a `CUSTOMER` account |
| POST | `/api/v1/users/login` | Public | Bean Validation; account status; password | Issue a JWT |
| GET | `/api/v1/users/me` | Bearer JWT | none; user resolved from `X-Username` | The caller's profile |
| GET | `/api/v1/users/{id}` | Bearer JWT | none (no ownership check) | Any user's profile by id |
| PUT | `/api/v1/users/{id}` | Bearer JWT | Bean Validation; no ownership check | Partial update of any user's profile |
| DELETE | `/api/v1/users/{id}` | Bearer JWT | none (no ownership check) | Soft-delete any user |
| GET | `/api/v1/users/internal/{username}` | Public | none | Any user's profile by username, no token needed |

## POST /api/v1/users/register

Creates an account with role `CUSTOMER` and status `ACTIVE`. Used by the frontend's register page, which then sends the user to the login page; registration does not log the user in.

**Auth:** Public. No service-side checks beyond validation and uniqueness.

**Request body** `RegisterRequest`

| Field | Type | Required | Validation (message) | Notes |
|---|---|---|---|---|
| `username` | string | yes | `@NotBlank` (`Username is required`); `@Size(min = 3, max = 50)` (`Username must be between 3 and 50 characters`); `@Pattern("^[a-zA-Z0-9_]+$")` (`Username can only contain letters, digits, and underscores`) | Unique, case-sensitive. Becomes the JWT `sub` and the platform-wide user name. Cannot be changed later. |
| `email` | string | yes | `@NotBlank` (`Email is required`); `@Email` (`Invalid email format`); `@Size(max = 100)` (`size must be between 0 and 100`) | Unique, case-sensitive. Cannot be changed later. |
| `password` | string | yes | `@NotBlank` (`Password is required`); `@Size(min = 8)` (`Password must be at least 8 characters`) | No complexity rule and no validated maximum, but more than 72 UTF-8 bytes fails with 500. Stored as a BCrypt hash (cost 10). |
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
      { "field": "password", "message": "Password must be at least 8 characters" }
    ],
    "message": "Validation failed",
    "path": "/api/v1/users/register",
    "status": 400,
    "timestamp": "2026-10-29T18:07:12.123456"
  }
  ```

- `409` `Username already taken: <username>`. The username is checked first, so a request that duplicates both gets this message.
- `409` `Email already registered: <email>`.
- `500` when the password is over 72 bytes, when two identical registrations race past the uniqueness check, or when the content type is not JSON.

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

1. Unknown username: `401` `Invalid username or password`.
2. Status `INACTIVE` or `SUSPENDED`: `401` `Account is inactive` or `Account is suspended`, whatever password was sent.
3. Wrong password: `401` `Invalid username or password`.

Also `400` when a field is blank or the JSON is malformed. There is no lockout or rate limit.

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

**Auth:** Bearer JWT at the gateway. No service-side checks: the user is resolved from the header.

**Headers**

| Name | In | Type | Required | Notes |
|---|---|---|---|---|
| `X-Username` | header | string | yes | Set by the gateway from the JWT `sub`, overwriting any client value. On a direct call to port 8081 whoever calls chooses it. |

**Responses**

- `200 OK` with a [`UserDTO`](#userdto), whatever the account's status.
- `401` from the gateway, empty body: no valid token.
- `404` `User not found: <username>`: the token names a user that no longer exists (for example after the database was reset).
- `400` `Required request header 'X-Username' ...`: header absent, which only happens on direct calls.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/users/me -H "Authorization: Bearer $TOKEN"
```

## GET /api/v1/users/{id}

Returns the profile with the given id.

**Auth:** Bearer JWT at the gateway. No service-side checks: any authenticated caller can read any user's profile, including email, phone number and addresses. The frontend's API client defines this call but no page uses it.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (int64) | yes | Must parse as a `Long`, otherwise 400 |

**Responses**

- `200 OK` with a [`UserDTO`](#userdto), whatever the account's status.
- `400` non-numeric id.
- `401` from the gateway, empty body.
- `404` `User not found with id: <id>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/users/42 -H "Authorization: Bearer $TOKEN"
```

## GET /api/v1/users/internal/{username}

Returns the profile of the named user. Labelled "Internal endpoint - get user by username (service-to-service)", but no service, script or frontend code calls it.

**Auth:** Public. The gateway lets `/api/v1/users/internal/` through without a token and user-service permits it, so anyone who can reach the gateway can read any account's personal data and probe which usernames exist. No service-side checks.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `username` | path | string | yes | Exact, case-sensitive match |

**Responses**

- `200 OK` with a [`UserDTO`](#userdto), whatever the account's status.
- `404` `User not found: <username>`.

**Side effects:** none.

**Example** (no token)

```bash
curl -s http://localhost:8080/api/v1/users/internal/admin
```

## PUT /api/v1/users/{id}

Partial profile update despite the verb. Each field that is present and non-null replaces the stored value; absent or `null` fields are left unchanged, so a field cannot be cleared back to null (an empty string is accepted). The frontend's profile page calls it with the id it got from `GET /me`.

**Auth:** Bearer JWT at the gateway. No service-side checks: any authenticated caller can update any user.

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

**Auth:** Bearer JWT at the gateway. No service-side checks: any authenticated caller can deactivate any account, `admin` included.

**Path parameters**

| Name | In | Type | Required | Constraints |
|---|---|---|---|---|
| `id` | path | integer (int64) | yes | Must parse as a `Long` |

**Responses**

- `204 No Content`, also when the user is already inactive.
- `400` non-numeric id.
- `401` from the gateway, empty body.
- `404` `User not found with id: <id>`.

**Side effects:** `UPDATE app_users SET status = 'INACTIVE', updated_at = now`. No events.

**Example**

```bash
curl -i -X DELETE http://localhost:8080/api/v1/users/42 -H "Authorization: Bearer $TOKEN"
```

## Operational endpoints

Served on port 8081 only. The gateway does not route these paths to user-service. All are unauthenticated.

| Method | Path | Purpose |
|---|---|---|
| GET | `/actuator/health` | Aggregate health with details (database, disk, discovery). Kubernetes also gets `/actuator/health/liveness` and `/actuator/health/readiness`. |
| GET | `/actuator/info`, `/actuator/metrics`, `/actuator/prometheus` | Info, metrics, Prometheus scrape |
| GET, POST | `/actuator/serviceregistry` | Read or set the Eureka status. The Kubernetes `preStop` hook POSTs `{"status":"OUT_OF_SERVICE"}` before shutdown. |
| GET | `/api-docs`, `/swagger-ui.html` | OpenAPI document and Swagger UI |

## Schemas

### UserDTO

`dto/UserDTO.java`, built by `UserService.toDTO()`. Returned by register, `/me`, `/{id}`, `/internal/{username}` and `PUT /{id}`. The password hash and `updatedAt` are never exposed.

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
| header | `alg` | string | Chosen from the secret's length: `HS256` for 32-47 bytes, `HS384` for 48-63, `HS512` for 64 or more. `HS384` with the default 55-byte secret. |
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
