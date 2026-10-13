#!/bin/bash
# ALB público para el frontend Fargate (DNS estable de Cognito).
# Uso: VPC_ID=vpc-xxx SUBNET_1=subnet-aaa SUBNET_2=subnet-bbb SG_ALB_PUBLIC=sg-xxx ./create-alb-public.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?}"
SUBNET_1="${SUBNET_1:?}"
SUBNET_2="${SUBNET_2:?}"
SG_ALB_PUBLIC="${SG_ALB_PUBLIC:?}"

ALB_ARN="$(aws elbv2 create-load-balancer \
  --name rrhh-alb-public \
  --scheme internet-facing \
  --type application \
  --subnets "$SUBNET_1" "$SUBNET_2" \
  --security-groups "$SG_ALB_PUBLIC" \
  --region "$REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)"

TG="$(aws elbv2 create-target-group \
  --name rrhh-tg-frontend \
  --protocol HTTP \
  --port 3000 \
  --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path / \
  --health-check-interval-seconds 30 \
  --matcher HttpCode=200 \
  --region "$REGION" \
  --query "TargetGroups[0].TargetGroupArn" --output text)"

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG}" \
  --region "$REGION" >/dev/null

PUBLIC_ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --region "$REGION" --query "LoadBalancers[0].DNSName" --output text)"

echo "PUBLIC_ALB_DNS=${PUBLIC_ALB_DNS}"
echo "FRONTEND_TG_ARN=${TG}"
echo "PUBLIC_ALB_ARN=${ALB_ARN}"
echo "Frontend: https://staging.ddz08ku6sazjt.amplifyapp.com"
echo "NEXTAUTH_URL=https://staging.ddz08ku6sazjt.amplifyapp.com"
echo "Callback Cognito: https://staging.ddz08ku6sazjt.amplifyapp.com/api/auth/callback/cognito"
