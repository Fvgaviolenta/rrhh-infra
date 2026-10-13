#!/bin/bash
# Crea 6 servicios Fargate + frontend, registrados en sus target groups.
# Uso: ver variables abajo. Subnets públicas + assignPublicIp ENABLED (pull ECR sin NAT).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-rrhh}"
SUBNET_1="${SUBNET_1:?}"
SUBNET_2="${SUBNET_2:?}"
SG_FARGATE_MS="${SG_FARGATE_MS:?}"
SG_FRONTEND="${SG_FRONTEND:?}"

NET_MS="awsvpcConfiguration={subnets=[${SUBNET_1},${SUBNET_2}],securityGroups=[${SG_FARGATE_MS}],assignPublicIp=ENABLED}"
NET_FE="awsvpcConfiguration={subnets=[${SUBNET_1},${SUBNET_2}],securityGroups=[${SG_FRONTEND}],assignPublicIp=ENABLED}"

svc() {
  local name="$1" td="$2" container="$3" port="$4" tg="$5" net="$6"
  echo "Servicio ${name}..."
  aws ecs create-service \
    --cluster "$CLUSTER" \
    --service-name "$name" \
    --task-definition "$td" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "$net" \
    --load-balancers "targetGroupArn=${tg},containerName=${container},containerPort=${port}" \
    --region "$REGION" >/dev/null
}

svc rrhh-identity rrhh-identity rrhh-identity 8081 "${TG_IDENTITY:?}" "$NET_MS"
svc rrhh-trabajadores rrhh-trabajadores rrhh-trabajadores 8082 "${TG_TRABAJADORES:?}" "$NET_MS"
svc rrhh-contratos rrhh-contratos rrhh-contratos 8083 "${TG_CONTRATOS:?}" "$NET_MS"
svc rrhh-asistencia rrhh-asistencia rrhh-asistencia 8084 "${TG_ASISTENCIA:?}" "$NET_MS"
svc rrhh-ausencias rrhh-ausencias rrhh-ausencias 8085 "${TG_AUSENCIAS:?}" "$NET_MS"
svc rrhh-notifications rrhh-notifications rrhh-notifications 8086 "${TG_NOTIFICATIONS:?}" "$NET_MS"
svc rrhh-frontend rrhh-frontend rrhh-frontend 3000 "${TG_FRONTEND:?}" "$NET_FE"

echo "Servicios Fargate creados en cluster ${CLUSTER}."
