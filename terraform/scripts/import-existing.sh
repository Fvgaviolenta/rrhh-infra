#!/usr/bin/env bash
# No crea nada en AWS: solo adopta al state de Terraform los recursos que ya existen (terraform import).
# Uso, desde terraform/:  export TF_VAR_db_password=...; DRY_RUN=1 scripts/import-existing.sh   (solo imprime)
set -euo pipefail
cd "$(dirname "$0")/.."

# IDs de la cuenta del lab (guía del 07-10, §16). Se pueden sobrescribir por variable de entorno.
CLUSTER="${CLUSTER:-rrhh}"
ALB_NAME="${ALB_NAME:-rrhh-alb-internal}"
API_ID="${API_ID:-5xqk65aw5e}"
AUTHORIZER_ID="${AUTHORIZER_ID:-2cxsd2}"
VPC_LINK_ID="${VPC_LINK_ID:-n8tuqb}"
POOL_ID="${POOL_ID:-us-east-1_OyyaRU7Bx}"
CLIENT_ID="${CLIENT_ID:-ujuivcn3okkjj63o05kfsous1}"
COGNITO_DOMAIN="${COGNITO_DOMAIN:-us-east-1oyyaru7bx}"
AMPLIFY_APP_ID="${AMPLIFY_APP_ID:-d3nglkihppyxa9}"
AMPLIFY_BRANCH="${AMPLIFY_BRANCH:-staging}"
DATA_INSTANCE_ID="${DATA_INSTANCE_ID:-i-0f57c224b729a704a}"
SG_ALB="${SG_ALB:-sg-02f11fa7d1f512813}"
SG_ECS="${SG_ECS:-sg-082b3027bd717b1c4}"
SG_DATA="${SG_DATA:-sg-0515150d94e9cd5e2}"
SERVICES="identity trabajadores contratos asistencia ausencias notifications"
DRY_RUN="${DRY_RUN:-0}"
IMPORT_DATA_EC2="${IMPORT_DATA_EC2:-0}"

STATE="$(terraform state list 2>/dev/null || true)"

# import <dirección> <id>: omite lo que ya está en el state y respeta DRY_RUN.
import() {
  local addr="$1" id="$2"
  if [ -z "$id" ] || [ "$id" = "None" ]; then
    echo "OMITIDO (no se encontró el id): $addr" >&2
    return 0
  fi
  if grep -qxF -- "$addr" <<<"$STATE"; then
    echo "ya está en el state: $addr"
    return 0
  fi
  echo "terraform import '$addr' '$id'"
  if [ "$DRY_RUN" != "1" ]; then
    terraform import -input=false "$addr" "$id"
  fi
}

# aws_value <comando aws...>: imprime el valor o vacío si la consulta falla.
aws_value() { aws "$@" --output text 2>/dev/null || true; }

import aws_ecs_cluster.rrhh "$CLUSTER"
import aws_ecr_repository.rrhh rrhh

for s in $SERVICES; do
  import "aws_cloudwatch_log_group.svc[\"$s\"]" "/ecs/rrhh-$s"
  tg="$(aws_value elbv2 describe-target-groups --names "rrhh-tg-$s" --query 'TargetGroups[0].TargetGroupArn')"
  import "aws_lb_target_group.svc[\"$s\"]" "$tg"
  if [ "$s" = "identity" ]; then
    import aws_ecs_service.identity "$CLUSTER/rrhh-$s"
  else
    import "aws_ecs_service.svc[\"$s\"]" "$CLUSTER/rrhh-$s"
  fi
done

alb_arn="$(aws_value elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn')"
import aws_lb.internal "$alb_arn"
if [ -n "$alb_arn" ] && [ "$alb_arn" != "None" ]; then
  listener_arn="$(aws_value elbv2 describe-listeners --load-balancer-arn "$alb_arn" --query 'Listeners[?Port==`80`].ListenerArn | [0]')"
  import aws_lb_listener.http "$listener_arn"
fi
echo "AVISO: las 21 reglas del ALB (aws_lb_listener_rule.path) no se importan; se recrean desde alb/listener-rules.json." >&2

import aws_apigatewayv2_vpc_link.main "$VPC_LINK_ID"
import aws_apigatewayv2_api.http "$API_ID"
import aws_apigatewayv2_authorizer.jwt "$API_ID/$AUTHORIZER_ID"
import aws_apigatewayv2_stage.default "$API_ID/\$default"

# Las dos rutas que define Terraform ya existen con esa clave; sin importarlas la creación falla por duplicado.
for key in "GET /api/v1/tenants/resolver" "ANY /api/v1/{proxy+}"; do
  rid="$(aws_value apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='$key'].RouteId | [0]")"
  import "aws_apigatewayv2_route.routes[\"$key\"]" "${rid:+$API_ID/$rid}"
done
integ="$(aws_value apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='ANY /api/v1/{proxy+}'].Target | [0]")"
integ="${integ#integrations/}"
import aws_apigatewayv2_integration.alb "${integ:+$API_ID/$integ}"

import aws_cognito_user_pool.main "$POOL_ID"
import aws_cognito_user_pool_client.spa "$POOL_ID/$CLIENT_ID"
import aws_cognito_user_pool_domain.main "$COGNITO_DOMAIN"

import aws_amplify_app.frontend "$AMPLIFY_APP_ID"
import aws_amplify_branch.staging "$AMPLIFY_APP_ID/$AMPLIFY_BRANCH"

import aws_security_group.alb "$SG_ALB"
import aws_security_group.ecs "$SG_ECS"
import aws_security_group.data "$SG_DATA"

# La EC2 de datos viva tiene otro AMI, subnet y user-data (con el broker retirado): importarla hace que el plan
# la reemplace y se pierden los datos de MySQL. Solo con IMPORT_DATA_EC2=1 y un respaldo previo.
if [ "$IMPORT_DATA_EC2" = "1" ]; then
  import aws_instance.data "$DATA_INSTANCE_ID"
else
  echo "AVISO: aws_instance.data no se importa (IMPORT_DATA_EC2=1 para hacerlo); ver README." >&2
fi
