# HTTP API (AWS API Gateway v2) — RRHH SaaS

Sustituye a `rrhh-gateway` **en AWS**. En local el API Manager sigue siendo `rrhh-gateway:8078`.

## Flujo

```text
Frontend → HTTP API (JWT Cognito + CORS + throttle)
        → VPC Link
        → ALB interno (DNS fijo)
        → Target groups por path
        → Fargate 8081–8086
```

## Rutas

| Route key | Auth | Destino |
| --- | --- | --- |
| `ANY /api/v1/{proxy+}` | JWT Cognito | Listener del ALB interno |
| `GET /api/v1/tenants/resolver` | none | Mismo ALB (identity) |

El ALB reparte por path (ver [`../alb/listener-rules.json`](../alb/listener-rules.json)).

## Script

[`create-http-api.sh`](create-http-api.sh) (CloudShell). Requiere `INTERNAL_ALB_DNS` / `ALB_ARN` ya creados.

El catálogo `GET /api/v1/catalogo` **no** se publica en managed (queda en el gateway local).

Throttle por defecto del stage `$default`: 30 req/s, burst 60 (equivalente a `RRHH_RATE_LIMIT_*` local).
