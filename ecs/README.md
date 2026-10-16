# ECS — artefactos

## Camino oficial (Fargate + ALB)

- [`fargate/`](fargate/) — task definitions `awsvpc` (placeholder `ACCOUNT_ID`, `DATA_HOST`, issuer).
- [`register-fargate.sh`](register-fargate.sh) — registra esas familias.
- [`create-security-groups.sh`](create-security-groups.sh)
- [`create-fargate-services.sh`](create-fargate-services.sh)
- [`../alb/`](../alb/) — ALB interno/público y path rules.
- [`../http-api/`](../http-api/) — HTTP API + VPC Link.

Imágenes en un solo repo ECR (`rrhh:<tag>`). Runbook: [`guia-de-despliegue-aws.md`](../../guia-de-despliegue-aws.md).

## Fallback lab (EC2 host network)

- `user-data-ecs.sh` — agent ECS en una EC2.
- `task-definitions/` — JSON `networkMode: host` (incluye `rrhh-gateway`).
- `register-tasks.sh` — registra las familias EC2.
