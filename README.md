# ecommerce-platform

Central repository for running the full e-commerce microservices stack.

## Repository layout

Clone all repos as siblings in the same parent directory:

```
parent-dir/
├── ecommerce-platform/          ← this repo (docker-compose lives here)
├── ecommerce-service-discovery/
├── ecommerce-api-gateway/
├── ecommerce-user-service/
├── ecommerce-product-service/
├── ecommerce-catalog-service/
├── ecommerce-order-service/
├── ecommerce-payment-service/
├── ecommerce-shipping-service/
├── ecommerce-review-service/
└── ecommerce-notification-service/
```

## Quick start

```bash
# 1. Clone all repos into the same parent directory
git clone <url>/ecommerce-platform
git clone <url>/ecommerce-service-discovery
git clone <url>/ecommerce-api-gateway
git clone <url>/ecommerce-user-service
git clone <url>/ecommerce-product-service
git clone <url>/ecommerce-catalog-service
git clone <url>/ecommerce-order-service
git clone <url>/ecommerce-payment-service
git clone <url>/ecommerce-shipping-service
git clone <url>/ecommerce-review-service
git clone <url>/ecommerce-notification-service

# 2. Build and start everything
cd ecommerce-platform
docker-compose up --build
```

## Service ports

| Service | Port |
|---|---|
| API Gateway | 8080 |
| Eureka Dashboard | 8761 |
| User Service | 8081 |
| Product Service | 8082 |
| Catalog Service | 8083 |
| Order Service | 8084 |
| Payment Service | 8085 |
| Shipping Service | 8086 |
| Review Service | 8087 |
| Notification Service | 8088 |
