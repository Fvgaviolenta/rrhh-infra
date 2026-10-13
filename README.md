# rrhh-infra

Configuración de infraestructura local y del laboratorio AWS.

- `init/`: scripts SQL ejecutados al crear el volumen de MySQL local.
- `.env.example`: variables compartidas para `docker compose` en el PC.
- `.env.aws.example`: variables de la EC2 del Learner Lab (copiar a `.env.aws`, `chmod 600`).
- `ecs/`: user-data, task definitions y script de registro para **ECS launch type EC2**.

Arranque local (solo datos) desde la raíz `PROYECTO/`:

```bash
docker compose up -d mysql redis rabbitmq
```

Plan B en el lab (toda la app con los mismos Dockerfiles):

```bash
docker compose -f docker-compose.lab.yml --env-file rrhh-infra/.env.aws up -d
```

Las migraciones de dominio las aplica cada microservicio con Flyway.

La guía paso a paso está en [`guia-de-despliegue-aws.md`](../guia-de-despliegue-aws.md).
