# GitHub Actions → ECR

Publica imágenes al repositorio ECR único `rrhh` (un tag por microservicio). El build **no** corre en el PC.

Los microservicios están en **repositorios GitHub separados** (cuenta personal, **sin Organization**). Los secrets **no se comparten**: hay que cargarlos en cada repo.

En este lab el Git root de cada MS **es** `backend/` (Dockerfile en `.`). Los YAML ya están en:

- `rrhh-identity/backend/.github/workflows/ecr-push.yml` (`TAG: identity`)
- igual para trabajadores, contratos, asistencia, ausencias, notifications
- `rrhh-frontend/.github/workflows/ecr-push.yml` (`TAG: frontend`)

No uses el workflow del monorepo (raíz del workspace) dentro de esos repos.

Plantilla genérica: [`ecr-push-service.yml`](ecr-push-service.yml) (deja `TAG` hardcodeado). `rrhh-infra` no publica imagen. `rrhh-gateway` no lleva workflow.

## IAM

Policy: [`iam-ecr-push.json`](iam-ecr-push.json) (sustituye `ACCOUNT_ID`). Usuario: `github-actions-ecr`. Las mismas keys se pegan en cada repo.

## Secrets y variables

Clics y tablas: paso 3 de [`guia-de-despliegue-aws.md`](../../guia-de-despliegue-aws.md) (§4.3).

Resumen (repetir en **cada** repo de imagen). Todo es ámbito **Repository**, no Environment:

| Ámbito GitHub | Name | Valor |
| --- | --- | --- |
| **Repository secret** | `AWS_ACCESS_KEY_ID` | Access key IAM |
| **Repository secret** | `AWS_SECRET_ACCESS_KEY` | Secret key |
| **Repository secret** | `AWS_SESSION_TOKEN` | Solo Learner Lab (caduca; Update en todos los repos) |
| **Repository variable** | `AWS_REGION` | `us-east-1` |
| **Repository variable** | `ECR_REPOSITORY` | `rrhh` |
| **Repository secret** | `NEXT_PUBLIC_API_GATEWAY_URL` | Solo `rrhh-frontend` |

El tag (`identity`, `frontend`, …) va en el YAML, no como repository variable.

Ruta: **repo → Settings → Secrets and variables → Actions**. Botones: **New repository secret** / **New repository variable**. No uses Environment secret/variable.
