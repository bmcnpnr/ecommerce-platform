# Ecommerce platform documentation

Technical documentation for the ecommerce microservices platform: what each
service does, how the services talk to each other, how a purchase flows
through them, how to run, operate and change the system, and what is known to
be wrong with it. Everything here was written from the code on `develop`
(October 2026), and it names the classes it describes so you can check it.

The platform is 13 repositories: eight business services, an API gateway, a
Eureka registry, a React storefront, a monitoring configuration repo, and this
orchestration repo. They run as 38 containers under Docker Compose or
Kubernetes.

## Start here

1. [Architecture](architecture.md): the big picture, the service catalog, the tech stack, deployment, build and testing.
2. [Communication](communication.md): gateway routing, Feign calls, Kafka topics, discovery, resilience.
3. [End-to-end flows](flows.md): registration, browsing, a full purchase, cancellation, shipping and reviews, as sequence diagrams.
4. The service page for whatever you're working on (below).
5. [Onboarding](onboarding.md): run it locally and make your first change.

## Services

| Service | Purpose | Port | Deep dive | API |
|---|---|---|---|---|
| api-gateway | Entry point: routing, JWT validation, identity headers, unified Swagger UI | 8080 | [api-gateway](services/api-gateway.md) | — |
| service-discovery | Eureka registry | 8761 | [service-discovery](services/service-discovery.md) | — |
| user-service | Accounts, registration, login, JWT issuance | 8081 | [user-service](services/user-service.md) | [API](api/user-service.md) |
| product-service | Products, categories and stock: the source of truth | 8082 | [product-service](services/product-service.md) | [API](api/product-service.md) |
| catalog-service | Storefront read model in MongoDB, search, merchandising | 8083 | [catalog-service](services/catalog-service.md) | [API](api/catalog-service.md) |
| order-service | Orders, items, stock reservation, order lifecycle | 8084 | [order-service](services/order-service.md) | [API](api/order-service.md) |
| payment-service | Simulated payments and refunds | 8085 | [payment-service](services/payment-service.md) | [API](api/payment-service.md) |
| shipping-service | Shipments, tracking, delivery status | 8086 | [shipping-service](services/shipping-service.md) | [API](api/shipping-service.md) |
| review-service | Product reviews, ratings and votes | 8087 | [review-service](services/review-service.md) | [API](api/review-service.md) |
| notification-service | Consumes every business event (logs notifications today) | 8088 | [notification-service](services/notification-service.md) | — |
| frontend | React storefront and admin UI | 3000 | [frontend](frontend.md) | — |

## Reference

| Document | Contents |
|---|---|
| [API reference](api/README.md) | Conventions, the full endpoint index, links to each service's reference, Swagger UI and the OpenAPI files |
| [OpenAPI specs](api/openapi/) | Generated OpenAPI 3.1 documents, one per service, for Postman, Insomnia or codegen |
| [Event catalog](events.md) | Every Kafka topic: producer, consumers, key, payload schema, wire format, failure handling |
| [Data model](data-model.md) | Every database and table, ER diagrams, the cross-service references no foreign key enforces |
| [Security](security.md) | Authentication, identity propagation, authorization (and its gaps), secrets, exposure |
| [Observability](observability.md) | Metrics, logs, traces, dashboards, alerts, and how to investigate with them |
| [Frontend](frontend.md) | The SPA's structure, routing, auth handling and API usage |

## Operating and changing the system

| Document | Contents |
|---|---|
| [Onboarding](onboarding.md) | Prerequisites, first run, the everyday dev loop, debugging, tests, conventions |
| [Runbook](runbook.md) | Symptom → cause → fix, Kafka and database procedures, secret rotation, incident history |
| [Platform README](../README.md) | Build scripts, ports, databases, resource limits, test layers |
| [Kubernetes](../k8s/README.md) | The k8s deployment and everything that differs from compose |
| [CI/CD](../CICD.md) | Pipelines, image tags, Docker Hub publishing |

## Decisions and findings

| Document | Contents |
|---|---|
| [Architecture decisions](adr/README.md) | 12 ADRs reconstructed from the code: why the platform looks the way it does |
| [Findings and roadmap](findings.md) | Prioritized bugs, security gaps and technical debt found while writing these docs, with suggested fixes |

## About these docs

- **Format:** Markdown with [Mermaid](https://mermaid.js.org/) diagrams. They render on GitHub, in IntelliJ (Markdown plugin, Mermaid enabled), and in VS Code with a Mermaid preview extension.
- **PDF:** `cd docs-pdf && npm install && npm run build` writes everything here into one PDF at `dist/ecommerce-platform-documentation.pdf`. It has a cover, a clickable contents page listing every document and section, one part per group, and a bookmark tree (part > document > section) for the viewer's sidebar. `npm run watch` rebuilds on every save. New or deleted pages are picked up automatically. `PARTS` in `docs-pdf/build-pdf.mjs` only sets grouping and order; a page it doesn't name lands at the end of its folder's part, or under "Other documents". It needs a local Chrome or Edge (or `CHROME_PATH`).
- **Code references** name the repository-relative file and the class or method, never line numbers, so they survive edits.
- **Keeping them true:** when you change an endpoint, an event or a table, update the service page and the API reference in the same pull request. Regenerate the OpenAPI files with `../export-openapi.sh` against a running stack. Cross-service contracts are also pinned by Pact, so a forgotten consumer update fails a build. A forgotten doc update does not.
