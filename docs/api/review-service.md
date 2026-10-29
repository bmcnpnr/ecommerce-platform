# Review service API reference

Base URL through the gateway: `http://localhost:8080`. Direct (bypasses the
gateway and its JWT check, dev only): `http://localhost:8087`. Live OpenAPI from
springdoc: `http://localhost:8087/api-docs`, Swagger UI
`http://localhost:8087/swagger-ui.html`. The gateway's unified Swagger UI loads
the same spec through `/api-docs/review-service`.

Service overview, rules and known issues: [review-service](../services/review-service.md).

## Conventions

**Content type.** Request and response bodies are JSON (`application/json`).

**Authentication.** The gateway lets `GET /api/v1/reviews/product/**` through
without a token. Every other review endpoint needs `Authorization: Bearer <JWT>`;
without a valid one the gateway answers 401 with an empty body and the request
never reaches the service. The service itself checks no token. It reads the
headers the gateway sets from the token and enforces identity and ownership:

| Header | Read by | Default if absent | Meaning |
|---|---|---|---|
| `X-Username` | create, update, delete, vote, reads of unapproved reviews | none: 401 `Authentication required` on writes | the caller's username. It becomes the review's `customerId` and is compared with it for ownership. Over 255 characters or a NUL byte: 400. |
| `X-User-Role` | delete, moderate, unapproved reads | treated as not admin | exactly `ADMIN` (no trimming, no case folding, no `ROLE_` prefix) |
| `X-User-Id` | — | — | ignored |

On direct calls to port 8087 whoever calls chooses the headers. Through the gateway
the authenticated routes always carry them. Responses carry `nosniff` and `no-store`.

Get a token with `POST /api/v1/users/login` (see [user-service](../services/user-service.md)).
The seeded administrator is `admin`, with the password from `ADMIN_PASSWORD` in
`ecommerce-platform/.env`. For a customer, register one first with
`POST /api/v1/users/register`.

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/users/login \
  -H 'Content-Type: application/json' -d '{"username":"alice","password":"<password>"}' \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
```

Run the examples from Git Bash or WSL, not PowerShell 5.1, which strips the
quotes out of JSON arguments to `curl.exe`.

**Correlation ID.** Send `X-Correlation-Id` to choose one (`^[A-Za-z0-9._-]{1,64}$`). Otherwise the service
generates a UUID. Either way it comes back in the `X-Correlation-Id` response
header and in every error body.

**Error body.** Every error the service produces has this shape
(`exception/ErrorResponse.java`):

```json
{
  "timestamp": "2026-10-29T14:30:15.123456",
  "status": 404,
  "error": "Not Found",
  "message": "Review not found with id: 99",
  "path": "/api/v1/reviews/99",
  "correlationId": "0b9f3c1e-6d2a-4f57-9a43-3d8f2b7c5e10",
  "fieldErrors": null
}
```

| Field | Type | Notes |
|---|---|---|
| `timestamp` | string | `LocalDateTime`, ISO-8601 without offset |
| `status` | integer | HTTP status |
| `error` | string | see the table below |
| `message` | string | see the table below |
| `path` | string | request URI |
| `correlationId` | string | same value as the response header |
| `fieldErrors` | array of `{ "field": string, "message": string }`, or `null` | only filled for validation failures |

**Exception to status mapping** (`exception/GlobalExceptionHandler.java`):

| Exception | Status | `error` | `message` |
|---|---|---|---|
| `ReviewNotFoundException` | 404 | `Not Found` | `Review not found with id: <id>` |
| `DuplicateReviewException` | 409 | `Conflict` | `Customer <username> has already reviewed product <productId>` |
| `UnauthenticatedException` | 401 | `Unauthorized` | `Authentication required` |
| `UnauthorizedReviewAccessException` | 403 | `Forbidden` | `Access denied` (a read, moderate) or the specific text: `Only the review author can update this review`, `Only the review author or an admin can delete this review`, `Authors cannot vote on their own review` |
| `MethodArgumentNotValidException` (Bean Validation on a body) | 400 | `Validation Failed` | `Request validation failed`, with `fieldErrors` |
| `HttpRequestMethodNotSupportedException` | 405 | `Method Not Allowed` | `Method not allowed` |
| `HttpMessageNotReadableException` (missing or malformed JSON) | 400 | `Bad Request` | `Malformed request body` |
| `MethodArgumentTypeMismatchException` (e.g. a non-numeric ID or an unknown `status` value) | 400 | `Bad Request` | `Invalid value for parameter '<name>'` |
| `MissingServletRequestParameterException`, `ServletRequestBindingException` | 400 | `Bad Request` | `Missing or invalid request parameter` |
| not acceptable / unsupported `Content-Type` / unmapped path | 406 / 415 / 404 | | `Not acceptable` / `Unsupported media type` / `Resource not found` |
| unique-constraint race (duplicate review, first vote) | 409 | `Conflict` | `Resource already exists or violates a constraint` |
| anything else | 500 | `Internal Server Error` | `An unexpected error occurred` (the exception is logged at ERROR) |

"Anything else" includes product-service saying the product does not exist, or product-service being unreachable (`POST /api/v1/reviews`).

Validation messages are Hibernate Validator's English defaults: `must not be
null`, `must not be blank`, `must be greater than or equal to 1`, `must be less
than or equal to 5`, `size must be between 3 and 255`, `size must be between 10
and 2000`. The order of `fieldErrors` is not fixed.

**Pagination.** None. List endpoints return a plain JSON array of everything that
matches, in no defined order (the queries have no `ORDER BY`).

**Formats.** `LocalDateTime` fields are ISO-8601 strings without an offset, for
example `2026-10-29T14:30:15.123456` (Boot 4's Jackson 3 default). They are
in the JVM's default zone; the images set no `TZ`. `rating` is an integer.
`averageRating` is a number with at most one decimal. Vote counts are integers.

## Endpoints

| Method | Path | Gateway auth | Service-side checks | Summary |
|---|---|---|---|---|
| `POST` | `/api/v1/reviews` | Bearer JWT | `X-Username` required (401); the author is `X-Username` | create a review |
| `GET` | `/api/v1/reviews/{id}` | Bearer JWT | unapproved: author or `ADMIN` | get one review |
| `GET` | `/api/v1/reviews/product/{productId}` | public | none | list a product's reviews |
| `GET` | `/api/v1/reviews/product/{productId}/summary` | public | none | a product's rating summary |
| `GET` | `/api/v1/reviews/customer/{customerId}` | Bearer JWT | unapproved ones only for that user or `ADMIN` | list one user's reviews |
| `PUT` | `/api/v1/reviews/{id}` | Bearer JWT | `X-Username` must be the author | edit a review |
| `DELETE` | `/api/v1/reviews/{id}` | Bearer JWT | author, or `X-User-Role` `ADMIN` | delete a review |
| `PATCH` | `/api/v1/reviews/{id}/moderate` | `ADMIN` | `ADMIN` | set the moderation status |
| `POST` | `/api/v1/reviews/{id}/vote` | Bearer JWT | `X-Username` required; not the author; review `APPROVED` | cast or change a vote |

---

## POST /api/v1/reviews

Creates a review in status `PENDING`. The service first asks product-service
whether the product exists, then rejects a second review of the same product by
the same user.

**Auth:** Bearer JWT. The author is `X-Username`; without it the service answers 401.

**Request body** `CreateReviewRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `productId` | integer (int64) | yes | `@NotNull` | product-service's product ID |
| `rating` | integer (int16) | yes | `@NotNull`, `@Min(1)`, `@Max(5)` | |
| `title` | string | yes | `@NotBlank`, `@Size(min = 3, max = 255)` | |
| `body` | string | yes | `@NotBlank`, `@Size(min = 10, max = 2000)` | |

```json
{
  "productId": 1,
  "rating": 5,
  "title": "Great mouse",
  "body": "Comfortable, precise and the battery lasts for weeks."
}
```

**Responses**

- **201** [`ReviewDTO`](#reviewdto) with `status: "PENDING"` and both vote counts 0.

  ```json
  {
    "id": 11,
    "productId": 1,
    "customerId": "alice",
    "rating": 5,
    "title": "Great mouse",
    "body": "Comfortable, precise and the battery lasts for weeks.",
    "status": "PENDING",
    "helpfulVotes": 0,
    "unhelpfulVotes": 0,
    "createdAt": "2026-10-29T14:30:15.123456",
    "updatedAt": "2026-10-29T14:30:15.123456"
  }
  ```

- **400** validation failure (with `fieldErrors`), or a missing or unparsable body.
- **409** this username already reviewed this product.
- **500** the product does not exist, **or** product-service is unavailable (no instance, connection refused after 3 attempts, 10 s read timeout, any HTTP error). The body only says `An unexpected error occurred`.

**Side effects:** one Feign call `GET /api/v1/products/{productId}` to
product-service (body discarded); one `INSERT` into `reviews`. No events.

**Example**

```bash
curl -s -X POST http://localhost:8080/api/v1/reviews \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"productId":1,"rating":5,"title":"Great mouse","body":"Comfortable, precise and the battery lasts for weeks."}'
```

---

## GET /api/v1/reviews/{id}

Returns one review. `PENDING` and `REJECTED` reviews are visible only to their author and `ADMIN`.

**Auth:** Bearer JWT at the gateway. For an unapproved review of someone else the service answers 403 `Access denied` (401 without `X-Username`).

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | numeric, otherwise 400 |

**Responses**

- **200** [`ReviewDTO`](#reviewdto).
- **400** non-numeric `id`.
- **404** `Review not found with id: <id>`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/reviews/11 -H "Authorization: Bearer $TOKEN"
```

---

## GET /api/v1/reviews/product/{productId}

Lists a product's reviews. By default only `APPROVED` ones, which is what the
product page shows. With `approvedOnly=false` an `ADMIN` gets every status; anyone else still gets only approved reviews. The
admin moderation page uses that.

**Auth:** Public at the gateway. `approvedOnly=false` is honoured for `ADMIN` only.

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `productId` | path | integer (int64) | yes | — | not checked against product-service; an unknown ID returns `[]` |
| `approvedOnly` | query | boolean | no | `true` | `false` includes `PENDING` and `REJECTED`, for `ADMIN` only |

**Responses**

- **200** array of [`ReviewDTO`](#reviewdto), possibly empty, unordered, not paginated.

  ```json
  [
    {
      "id": 11,
      "productId": 1,
      "customerId": "bob",
      "rating": 4,
      "title": "Solid",
      "body": "Does what it says on the box, no complaints so far.",
      "status": "APPROVED",
      "helpfulVotes": 3,
      "unhelpfulVotes": 1,
      "createdAt": "2026-10-28T09:12:44.501233",
      "updatedAt": "2026-10-28T10:02:10.118020"
    }
  ]
  ```

- **400** non-numeric `productId` or non-boolean `approvedOnly`.

**Side effects:** none. Each review's votes are loaded with a separate query.

**Example**

```bash
curl -s 'http://localhost:8080/api/v1/reviews/product/1'
curl -s 'http://localhost:8080/api/v1/reviews/product/1?approvedOnly=false'
```

---

## GET /api/v1/reviews/product/{productId}/summary

The rating summary for a product's page.

**Auth:** Public at the gateway.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `productId` | path | integer (int64) | yes | — | not checked against product-service |

**Responses**

- **200** [`ReviewSummaryDTO`](#reviewsummarydto). An unknown product, or one without approved reviews, gives `averageRating: 0.0` and zeros everywhere.

  ```json
  {
    "productId": 1,
    "averageRating": 4.3,
    "totalReviews": 4,
    "approvedReviews": 3,
    "ratingDistribution": { "1": 0, "2": 0, "3": 0, "4": 2, "5": 1 }
  }
  ```

  Here three approved reviews rated 4, 4 and 5 average 4.33, shown as 4.3; the fourth review is pending, so it counts only in `totalReviews`.

- **400** non-numeric `productId`.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/reviews/product/1/summary
```

---

## GET /api/v1/reviews/customer/{customerId}

Lists the reviews one user wrote. `PENDING` and `REJECTED` ones are included only when the caller is that user or `ADMIN`; they are filtered out otherwise.

**Auth:** Bearer JWT at the gateway.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `customerId` | path | string | yes | — | the author's **username** (what `X-Username` carried at creation), not the numeric user ID |

**Responses**

- **200** array of [`ReviewDTO`](#reviewdto), possibly empty, unordered, not paginated.

**Side effects:** none.

**Example**

```bash
curl -s http://localhost:8080/api/v1/reviews/customer/alice -H "Authorization: Bearer $TOKEN"
```

---

## PUT /api/v1/reviews/{id}

Edits the caller's own review. Fields left out or `null` keep their values. Every
successful edit puts the review back to `PENDING` for re-moderation and sets
`updatedAt`.

**Auth:** Bearer JWT. `X-Username` must equal the review's `customerId`. Admins are not exempt.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Request body** `UpdateReviewRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `rating` | integer (int16) | no | `@Min(1)`, `@Max(5)` | |
| `title` | string | no | `@Size(min = 3, max = 255)` | no `@NotBlank`: whitespace passes |
| `body` | string | no | `@Size(min = 10, max = 2000)` | no `@NotBlank`: whitespace passes |

```json
{ "rating": 4, "body": "Still good after a month, but the scroll wheel squeaks." }
```

**Responses**

- **200** the updated [`ReviewDTO`](#reviewdto), now `PENDING`.
- **400** validation failure, or a missing or unparsable body. `{}` is valid and only resets the status.
- **403** `Only the review author can update this review`.
- **404** unknown `id`.

**Side effects:** one `UPDATE` of `reviews`. The review leaves the default product listing until it is approved again.

**Example**

```bash
curl -s -X PUT http://localhost:8080/api/v1/reviews/11 \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"rating":4,"body":"Still good after a month, but the scroll wheel squeaks."}'
```

---

## DELETE /api/v1/reviews/{id}

Deletes a review and all of its votes.

**Auth:** Bearer JWT. Allowed for the author (`X-Username`) or when `X-User-Role` is exactly `ADMIN`; 401 without `X-Username`.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Responses**

- **204** no body.
- **403** `Only the review author or an admin can delete this review`.
- **404** unknown `id`.

**Side effects:** deletes the row in `reviews` and its rows in `review_votes`.

**Example**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X DELETE http://localhost:8080/api/v1/reviews/11 \
  -H "Authorization: Bearer $TOKEN"
```

---

## PATCH /api/v1/reviews/{id}/moderate

Sets a review's moderation status. Any status can be set from any status.

**Auth:** `ADMIN` only: 403 at the gateway unless the role is exactly `ADMIN`, and again in the service (`401` without identity, `403 Access denied`).

**Path / query parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |
| `status` | query | string | yes | — | `PENDING`, `APPROVED` or `REJECTED`, case-sensitive |

There is no request body.

**Responses**

- **200** the updated [`ReviewDTO`](#reviewdto).
- **400** `status` missing or not one of the three values.
- **404** unknown `id`.

**Side effects:** one `UPDATE` of `reviews` (`status`, `updated_at`). An `APPROVED` review starts appearing in the default listing and in the summary.

**Example**

```bash
ADMIN_TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/users/login \
  -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -s -X PATCH 'http://localhost:8080/api/v1/reviews/11/moderate?status=APPROVED' \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

---

## POST /api/v1/reviews/{id}/vote

Records whether the caller found a review helpful. A user has at most one vote
per review: voting again overwrites the earlier vote. A vote can't be withdrawn.
An author cannot vote on their own review, and only `APPROVED` reviews take votes.

**Auth:** Bearer JWT. The voter is `X-Username`; 401 without it.

**Path parameters**

| Name | In | Type | Required | Default | Constraints |
|---|---|---|---|---|---|
| `id` | path | integer (int64) | yes | — | |

**Request body** `VoteRequest`

| Field | Type | Required | Validation | Notes |
|---|---|---|---|---|
| `helpful` | boolean | yes | `@NotNull` | `true` = helpful, `false` = not helpful |

```json
{ "helpful": true }
```

**Responses**

- **200** the [`ReviewDTO`](#reviewdto) with recounted `helpfulVotes` and `unhelpfulVotes`.
- **400** `helpful` missing or `null`, or an unparsable body.
- **403** `Authors cannot vote on their own review`.
- **404** unknown `id`, or a review that is not `APPROVED`.
- **409** two first votes by the same user on the same review raced into the unique constraint.

**Side effects:** an `INSERT` into, or an `UPDATE` of, `review_votes`. The review's `updatedAt` does not change.

**Example**

```bash
curl -s -X POST http://localhost:8080/api/v1/reviews/11/vote \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"helpful":true}'
```

---

## Schemas

### ReviewDTO

`dto/ReviewDTO.java`. Returned by every endpoint that returns a review.

| Field | JSON type | Java type | Notes |
|---|---|---|---|
| `id` | integer | `Long` | |
| `productId` | integer | `Long` | product-service's product ID |
| `customerId` | string | `String` | the author's username |
| `rating` | integer | `Short` | 1 to 5 |
| `title` | string | `String` | |
| `body` | string | `String` | |
| `status` | string | `ReviewStatus` | `PENDING`, `APPROVED` or `REJECTED` |
| `helpfulVotes` | integer | `long` | votes with `helpful = true` |
| `unhelpfulVotes` | integer | `long` | votes with `helpful = false` |
| `createdAt` | string | `LocalDateTime` | ISO-8601, no offset |
| `updatedAt` | string | `LocalDateTime` | ISO-8601, no offset. Changes on edit and moderation, not on votes. |

### ReviewSummaryDTO

`dto/ReviewSummaryDTO.java`.

| Field | JSON type | Java type | Notes |
|---|---|---|---|
| `productId` | integer | `Long` | echoes the path |
| `averageRating` | number | `double` | mean of `APPROVED` ratings, rounded half-up to one decimal; `0.0` if none |
| `totalReviews` | integer | `long` | reviews of the product in **any** status |
| `approvedReviews` | integer | `long` | `APPROVED` reviews |
| `ratingDistribution` | object | `Map<Integer, Long>` | keys `"1"` to `"5"`, always all present; values count `APPROVED` reviews per rating |

### CreateReviewRequest

See [POST /api/v1/reviews](#post-apiv1reviews).

### UpdateReviewRequest

See [PUT /api/v1/reviews/{id}](#put-apiv1reviewsid).

### VoteRequest

See [POST /api/v1/reviews/{id}/vote](#post-apiv1reviewsidvote).

### ErrorResponse

See [Conventions](#conventions).

### ReviewStatus

| Value | Meaning |
|---|---|
| `PENDING` | new or edited, awaiting moderation; not in the default listing or the summary |
| `APPROVED` | shown in the default listing and counted in the summary |
| `REJECTED` | hidden from the default listing and the summary |
