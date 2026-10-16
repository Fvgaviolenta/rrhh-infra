#!/bin/bash
# Task definitions Fargate (awsvpc) con LabRole (execution + task).
# Uso:
#   ACCOUNT_ID=111111111111 \
#   COGNITO_ISSUER=https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXX \
#   DATA_HOST=172.31.x.x \
#   ./register-fargate.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:?Falta ACCOUNT_ID}"
COGNITO_ISSUER="${COGNITO_ISSUER:?Falta COGNITO_ISSUER}"
DATA_HOST="${DATA_HOST:?Falta DATA_HOST (IP privada de la EC2 de datos)}"
POOL_ID="${COGNITO_ISSUER##*/}"
DIR="$(cd "$(dirname "$0")/fargate" && pwd)"

for file in "$DIR"/*.json; do
  tmp="$(mktemp)"
  sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
      -e "s/DATA_HOST/${DATA_HOST}/g" \
      -e "s|us-east-1_REPLACE|${POOL_ID}|g" \
      -e "s|https://cognito-idp.us-east-1.amazonaws.com/us-east-1_REPLACE|${COGNITO_ISSUER}|g" \
      "$file" > "$tmp"
  echo "Registrando $(basename "$file")..."
  aws ecs register-task-definition --region "$REGION" --cli-input-json "file://${tmp}"
  rm -f "$tmp"
done
