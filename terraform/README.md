# Terraform de RRHH SaaS en AWS

Crea la arquitectura completa del lab en `us-east-1`: red y security groups, EC2 de datos (MySQL y Redis en Docker), ECR, cluster ECS Fargate con 6 microservicios, ALB interno con 21 reglas de path, HTTP API con JWT, Cognito, Amplify y una cola SQS con DLQ para los eventos. No crea roles ni políticas IAM: usa `LabRole` y `LabInstanceProfile`.

## Requisitos

- Terraform `>= 1.11` (las pruebas usan `override_during`, que 1.10 no reconoce; `terraform test` verificado con 1.11.4 y 1.14.0) y proveedor `hashicorp/aws ~> 6.0`.
- Credenciales del Learner Lab en `~/.aws/credentials` (`aws_access_key_id`, `aws_secret_access_key`, `aws_session_token`). Caducan con la sesión: si aparece `ExpiredToken`, pega las nuevas y repite.
- AWS CLI y `bash` en la máquina que aplica: los usan `scripts/import-existing.sh`, la subida del frontend y la espera de MySQL (`terraform_data.data_ready`, desactivable con `wait_for_data = false`).

## Mapa de archivos

| Archivo | Contenido |
| --- | --- |
| `versions.tf`, `variables.tf`, `locals.tf` | Proveedor, variables y el mapa de 6 servicios (puertos 8081-8086) |
| `network.tf` | VPC por defecto, 2 subnets, `LabRole`, 4 security groups y sus reglas |
| `data_tier.tf`, `secrets.tf`, `templates/` | EC2 de datos y contraseña de la base en SSM `SecureString` |
| `alb.tf` | ALB interno, 6 target groups y reglas de `../alb/listener-rules.json` |
| `sqs.tf` | Cola de eventos y DLQ (5 recepciones) |
| `cognito.tf`, `amplify.tf` | User pool, dominio, app client público, su estilo de managed login y app de Amplify |
| `ecr.tf`, `ecs.tf` | Repositorio `rrhh`, log groups, cluster, task definitions y servicios |
| `apigw.tf`, `outputs.tf` | VPC Link, HTTP API y salidas (incluye `vite_env`) |
| `tests/infra.tftest.hcl` | Pruebas con `mock_provider`, no tocan la cuenta |
| `scripts/import-existing.sh` | Adopta al state lo que ya existe |

Las reglas del ALB salen de `../alb/listener-rules.json`; para agregar una ruta se edita ese archivo.

## Variables

Todas están en `variables.tf` con descripción. Copia `terraform.tfvars.example` a `terraform.tfvars` (ignorado por git) y ajusta lo necesario. La contraseña de la base (`db_password`) no tiene valor por defecto y no va en archivos: `export TF_VAR_db_password=...`. Lo mismo para `TF_VAR_google_client_secret`; el proveedor Google solo se crea si `google_client_id` y `google_client_secret` están ambos definidos.

## Verificar sin tocar la cuenta

```bash
cd terraform
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test
```

## Orden de aplicación

Los servicios ECS necesitan imágenes en ECR, así que la primera vez se aplica en dos tiempos:

1. `terraform init && terraform apply -target=aws_ecr_repository.rrhh -target=aws_sqs_queue.events -target=aws_instance.data -target=aws_vpc_security_group_egress_rule.data_open -target=aws_vpc_security_group_egress_rule.data_world -target=aws_vpc_security_group_ingress_rule.data_ssh -target=terraform_data.data_ready` (las reglas del security group van aparte porque `-target` no las arrastra; `data_ready` espera hasta 15 minutos a que MySQL y Redis respondan)
2. Publicar las imágenes con el CI (GitHub Actions) con los tags `identity`, `trabajadores`, `contratos`, `asistencia`, `ausencias` y `notifications`.
3. `terraform apply`

`identity` espera estado estable (`wait_for_steady_state`) y los otros cinco servicios dependen de él. `terraform apply` es manual: este repositorio nunca lo ejecuta por su cuenta.

## Variables del frontend

```bash
terraform output -json vite_env
```

Devuelve las variables `VITE_*` que lee el build de Vite: `VITE_API_GATEWAY_URL`, las seis `VITE_API_*`, `VITE_COGNITO_REGION`, `VITE_COGNITO_CLIENT_ID`, y `VITE_COGNITO_USER_POOL_ID`, `VITE_COGNITO_ISSUER` y `VITE_COGNITO_DOMAIN`, que `cognitoAuth.ts` y `oidcConfig.ts` exigen (sin ellas el frontend cae a los valores del pool vivo). Cópialas al `.env.production` antes de compilar.

## Subir el frontend a Amplify

La app de Amplify no tiene repositorio. Terraform crea la app y la rama; el build se sube como zip:

```bash
cd rrhh-frontend && npm run build && (cd dist && zip -r ../dist.zip .)
APP=$(aws amplify list-apps --query "apps[?name=='rrhh-frontend'].appId | [0]" --output text)
aws amplify create-deployment --app-id "$APP" --branch-name staging   # devuelve jobId y zipUploadUrl
curl -T dist.zip "<zipUploadUrl>"
aws amplify start-deployment --app-id "$APP" --branch-name staging --job-id <jobId>
```

La salida `next_steps` imprime el primer comando con los valores ya resueltos.

## Adoptar lo que ya existe (`terraform import`)

La cuenta del lab ya tiene el cluster, el ALB, el HTTP API, el pool de Cognito, la app de Amplify y los security groups. Para que Terraform no intente crearlos de nuevo:

```bash
cd terraform
export TF_VAR_db_password=...
DRY_RUN=1 scripts/import-existing.sh   # solo imprime los comandos
scripts/import-existing.sh             # los ejecuta
terraform plan -var-file=terraform.tfvars
```

Antes de importar o de aplicar, revisa esto:

- **Servicios ECS:** los vivos se llaman `rrhh-identity-service`, `rrhh-trabajadores`, `rrhh-contratos-service`, `rrhh-asistencia-service`, `rrhh-ausencias-service-<sufijo>` y `rrhh-notifications-service`. El nombre de un servicio no se puede cambiar: repítelo en `service_names` (ver `terraform.tfvars.example`) para que el import los adopte sin reemplazo, o bórralos antes del `apply` y deja que Terraform cree `rrhh-<servicio>`.
- **Capacity provider de la consola:** el cluster vivo tiene `Infra-ECS-Cluster-rrhh-ManagedInstancesCapacityProvider`; ponlo en `extra_capacity_providers` o Terraform intentará quitarlo.
- **Pool de Cognito:** `ignore_changes = [schema]` evita el reemplazo por `custom:tenat_id`. La protección contra borrado queda `ACTIVE` como el pool vivo: para `terraform destroy` pon antes `cognito_deletion_protection = "INACTIVE"` y aplica.
- **Espera de MySQL:** una EC2 de datos que ya existe nunca publica la señal de listo (`/rrhh/data/ready`), así que al adoptarla pon `wait_for_data = false` o el `apply` falla a los 15 minutos.
- **EC2 de datos:** fija `data_subnet_id` (la viva está en `subnet-0de6f3771ccbe252c`) si decides importarla.
- **Dominio de Cognito:** el vivo es `us-east-1oyyaru7bx`; pon `cognito_domain_prefix = "us-east-1oyyaru7bx"` en `terraform.tfvars`, o el plan intentará crear otro y reemplazar el vivo.
- **EC2 de datos:** el script no la importa. La instancia viva tiene otra subnet y otro `user_data`, y el plan la reemplazaría (se pierden los datos de MySQL). Importa con `IMPORT_DATA_EC2=1` solo con un respaldo, o deja que Terraform cree una nueva y migra los datos.
- **Reglas de los security groups:** Terraform crea sus reglas como recursos aparte y no importa las existentes. Si ya existen reglas iguales, la creación falla por duplicado: revócalas antes en la consola. En `rrhh-sg-data` queda además la regla heredada del puerto de mensajería retirado, que Terraform no administra: bórrala a mano.
- **HTTP API:** el API vivo tiene más rutas que las 2 de Terraform (`GET /api/v1/tenants/resolver` y `ANY /api/v1/{proxy+}`). Las demás no se administran; bórralas a mano.
- **Atributos que fuerzan reemplazo:** el pool vivo, los security groups vivos (descripción y nombre) y el esquema del pool (`tenat_id` en el vivo) pueden diferir del HCL; un atributo así se reemplaza o falla en el plan. Sin verificar contra la cuenta: ejecuta el import y revisa `terraform plan` antes de aplicar.
- **Reglas del ALB:** las 21 reglas no se importan, se recrean desde el JSON.
- **App client de Cognito:** Terraform deja `write_attributes = ["email", "name"]`. El client vivo puede permitir escribir `custom:role` y `custom:tenant_id` a cualquier usuario autenticado; el `apply` lo corrige. El backend sigue escribiéndolos con las APIs admin.

## Teardown

`terraform destroy` elimina todo lo que Terraform administra. Cuesta dinero mientras exista: el ALB y la EC2 de datos corren por hora. En el lab, destruye al terminar la sesión. El repositorio ECR se borra con sus imágenes (`force_delete`).

## Límites del lab

- Sin IAM: todas las tareas usan `LabRole` y la EC2 usa `LabInstanceProfile`.
- Las credenciales caducan con la sesión; un `apply` largo puede fallar a la mitad por eso.
- Sin NAT: los servicios Fargate usan IP pública para llegar a ECR y SSM.

## Supuestos sin verificar

No se pudieron comprobar sin aplicar contra la cuenta:

- Que el lab permita un cluster solo Fargate (si exige Managed Instances, usa `enable_managed_instances = true`; el proveedor `~> 6.0` soporta `managed_instances_provider`).
- Que las tareas Fargate puedan publicar y consumir de SQS con `LabRole`.
- Que `LabRole` pueda leer el `SecureString` de SSM y descifrarlo con KMS al arrancar las tareas y la EC2.
- Que el prefijo de dominio de Cognito (`rrhh-<cuenta>` por defecto) esté libre.
- Que `LabRole` pueda ejecutar `cognito-idp:Admin*` desde identity.
- La conexión JDBC usa `useSSL=false&allowPublicKeyRetrieval=true` (igual que las task definitions vivas): el tráfico a MySQL no va cifrado dentro de la VPC. Activar TLS queda pendiente de probar contra la instancia real.
- SQS en el código Java: contratos y ausencias publican con un outbox en MySQL y notifications consume por polling (AWS SDK v2). Terraform entrega `SQS_EVENTS_QUEUE_URL` y `AWS_REGION` a todos, y `RRHH_SQS_ENABLED=true` solo a esos tres; sin esa variable el código no publica ni consume.
