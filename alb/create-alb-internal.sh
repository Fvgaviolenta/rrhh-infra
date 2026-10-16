#!/bin/bash
# Crea ALB interno, 6 target groups (tipo ip) y rules de path.
# Ejecutar en CloudShell. Requiere VPC default con al menos 2 subnets.
#
# Uso:
#   VPC_ID=vpc-xxx SUBNET_1=subnet-aaa SUBNET_2=subnet-bbb \
#   SG_ALB_INTERNAL=sg-xxx ./create-alb-internal.sh
#
# Al terminar imprime INTERNAL_ALB_DNS. Pétalo en .env.aws y en el VPC Link.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?Falta VPC_ID}"
SUBNET_1="${SUBNET_1:?Falta SUBNET_1}"
SUBNET_2="${SUBNET_2:?Falta SUBNET_2}"
SG_ALB_INTERNAL="${SG_ALB_INTERNAL:?Falta SG_ALB_INTERNAL}"

echo "Creando ALB interno rrhh-alb-internal..."
ALB_ARN="$(aws elbv2 create-load-balancer \
  --name rrhh-alb-internal \
  --scheme internal \
  --type application \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_1" "$SUBNET_2" \
  --security-groups "$SG_ALB_INTERNAL" \
  --region "$REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)"

INTERNAL_ALB_DNS="$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --region "$REGION" \
  --query "LoadBalancers[0].DNSName" --output text)"

create_tg() {
  local name="$1" port="$2"
  aws elbv2 create-target-group \
    --name "$name" \
    --protocol HTTP \
    --port "$port" \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path /actuator/health \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --region "$REGION" \
    --query "TargetGroups[0].TargetGroupArn" --output text
}

echo "Creando target groups..."
TG_IDENTITY="$(create_tg rrhh-tg-identity 8081)"
TG_TRABAJADORES="$(create_tg rrhh-tg-trabajadores 8082)"
TG_CONTRATOS="$(create_tg rrhh-tg-contratos 8083)"
TG_ASISTENCIA="$(create_tg rrhh-tg-asistencia 8084)"
TG_AUSENCIAS="$(create_tg rrhh-tg-ausencias 8085)"
TG_NOTIFICATIONS="$(create_tg rrhh-tg-notifications 8086)"

echo "Listener HTTP:80 (default 404)..."
LISTENER_ARN="$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=fixed-response,FixedResponseConfig={StatusCode=404,ContentType=application/json,MessageBody=\"{\\\"codigo\\\":404,\\\"mensaje\\\":\\\"Ruta no enrutada\\\"}\"}" \
  --region "$REGION" \
  --query "Listeners[0].ListenerArn" --output text)"

add_rule() {
  local prio="$1" path="$2" tg="$3"
  aws elbv2 create-rule \
    --listener-arn "$LISTENER_ARN" \
    --priority "$prio" \
    --conditions "Field=path-pattern,Values=${path}" \
    --actions "Type=forward,TargetGroupArn=${tg}" \
    --region "$REGION" >/dev/null
}

add_rule 10 "/api/v1/auth*" "$TG_IDENTITY"
add_rule 11 "/api/v1/usuarios*" "$TG_IDENTITY"
add_rule 12 "/api/v1/tenants*" "$TG_IDENTITY"
add_rule 13 "/api/v1/plataforma*" "$TG_IDENTITY"
add_rule 20 "/api/v1/trabajadores*" "$TG_TRABAJADORES"
add_rule 21 "/api/v1/departamentos*" "$TG_TRABAJADORES"
add_rule 22 "/api/v1/cargos*" "$TG_TRABAJADORES"
add_rule 30 "/api/v1/contratos*" "$TG_CONTRATOS"
add_rule 31 "/api/v1/liquidaciones*" "$TG_CONTRATOS"
add_rule 40 "/api/v1/asistencia*" "$TG_ASISTENCIA"
add_rule 41 "/api/v1/marcas-asistencia*" "$TG_ASISTENCIA"
add_rule 50 "/api/v1/ausencias*" "$TG_AUSENCIAS"
add_rule 51 "/api/v1/solicitudes-ausencia*" "$TG_AUSENCIAS"
add_rule 60 "/api/v1/notificaciones*" "$TG_NOTIFICATIONS"

echo ""
echo "INTERNAL_ALB_DNS=${INTERNAL_ALB_DNS}"
echo "Copia ese valor a rrhh-infra/.env.aws y úsalo en el VPC Link de HTTP API."
echo "ALB_ARN=${ALB_ARN}"
echo "LISTENER_ARN=${LISTENER_ARN}"
