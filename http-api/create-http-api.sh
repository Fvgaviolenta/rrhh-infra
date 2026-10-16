#!/bin/bash
# HTTP API + VPC Link al ALB interno + JWT Cognito + CORS + throttle.
# Uso (CloudShell):
#   INTERNAL_ALB_DNS=internal-rrhh-alb-internal-xxxx.us-east-1.elb.amazonaws.com \
#   ALB_ARN=arn:aws:elasticloadbalancing:...:loadbalancer/app/rrhh-alb-internal/... \
#   COGNITO_USER_POOL_ID=us-east-1_XXX \
#   COGNITO_CLIENT_ID=yyyy \
#   PUBLIC_ALB_DNS=rrhh-alb-public-xxxx.us-east-1.elb.amazonaws.com \
#   SUBNET_1=subnet-aaa SUBNET_2=subnet-bbb \
#   SG_ALB_INTERNAL=sg-xxx \
#   ./create-http-api.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
INTERNAL_ALB_DNS="${INTERNAL_ALB_DNS:?Falta INTERNAL_ALB_DNS}"
ALB_ARN="${ALB_ARN:?Falta ALB_ARN}"
COGNITO_USER_POOL_ID="${COGNITO_USER_POOL_ID:?Falta COGNITO_USER_POOL_ID}"
COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:?Falta COGNITO_CLIENT_ID}"
PUBLIC_ALB_DNS="${PUBLIC_ALB_DNS:?Falta PUBLIC_ALB_DNS (frontend)}"
SUBNET_1="${SUBNET_1:?}"
SUBNET_2="${SUBNET_2:?}"
SG_ALB_INTERNAL="${SG_ALB_INTERNAL:?}"
ISSUER="https://cognito-idp.${REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}"

echo "VPC Link HTTP API → ALB interno..."
VPC_LINK_ID="$(aws apigatewayv2 create-vpc-link \
  --name rrhh-vpc-link \
  --subnet-ids "$SUBNET_1" "$SUBNET_2" \
  --security-group-ids "$SG_ALB_INTERNAL" \
  --region "$REGION" \
  --query VpcLinkId --output text)"

echo "Espera VPC Link AVAILABLE (puede tardar 1–2 min)..."
for _ in $(seq 1 24); do
  STATUS="$(aws apigatewayv2 get-vpc-link --vpc-link-id "$VPC_LINK_ID" --region "$REGION" --query VpcLinkStatus --output text)"
  echo "  status=$STATUS"
  if [ "$STATUS" = "AVAILABLE" ]; then break; fi
  sleep 5
done

API_ID="$(aws apigatewayv2 create-api \
  --name rrhh-http-api \
  --protocol-type HTTP \
  --cors-configuration "AllowOrigins=https://staging.ddz08ku6sazjt.amplifyapp.com,http://localhost:3000,AllowHeaders=Authorization,Content-Type,X-Empresa-Slug,X-Request-Id,AllowMethods=GET,POST,PUT,PATCH,DELETE,OPTIONS,ExposeHeaders=X-Request-Id" \
  --region "$REGION" \
  --query ApiId --output text)"

AUTH_ID="$(aws apigatewayv2 create-authorizer \
  --api-id "$API_ID" \
  --authorizer-type JWT \
  --identity-source '$request.header.Authorization' \
  --name cognito-jwt \
  --jwt-configuration "Audience=${COGNITO_CLIENT_ID},Issuer=${ISSUER}" \
  --region "$REGION" \
  --query AuthorizerId --output text)"

# HTTP API VPC Link integration a un ALB: IntegrationUri = listener ARN
LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" --query "Listeners[0].ListenerArn" --output text)"

INT_ID="$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --connection-type VPC_LINK \
  --connection-id "$VPC_LINK_ID" \
  --integration-uri "$LISTENER_ARN" \
  --payload-format-version 1.0 \
  --region "$REGION" \
  --query IntegrationId --output text)"

aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "ANY /api/v1/{proxy+}" \
  --target "integrations/${INT_ID}" \
  --authorization-type JWT \
  --authorizer-id "$AUTH_ID" \
  --region "$REGION" >/dev/null

# Resolver de empresa y (si aplica) preflight: JWT no aplica a OPTIONS (CORS lo cubre).
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /api/v1/tenants/resolver" \
  --target "integrations/${INT_ID}" \
  --authorization-type NONE \
  --region "$REGION" >/dev/null

STAGE="$(aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy \
  --default-route-settings "ThrottlingBurstLimit=60,ThrottlingRateLimit=30" \
  --region "$REGION" \
  --query StageName --output text)"

HTTP_API_URL="$(aws apigatewayv2 get-api --api-id "$API_ID" --region "$REGION" --query ApiEndpoint --output text)"

echo ""
echo "HTTP_API_URL=${HTTP_API_URL}"
echo "VPC_LINK_ID=${VPC_LINK_ID}"
echo "API_ID=${API_ID}"
echo "Pega HTTP_API_URL en .env.aws y reconstruye el frontend (NEXT_PUBLIC_API_GATEWAY_URL)."
