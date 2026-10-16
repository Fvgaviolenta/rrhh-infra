#!/bin/bash
# Registra las task definitions en ECS. Ejecutar en CloudShell o en la EC2 con AWS CLI.
# Uso: ACCOUNT_ID=111111111111 COGNITO_ISSUER=https://cognito-idp.us-east-1.amazonaws.com/us-east-1_XXX ./register-tasks.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:?Falta ACCOUNT_ID}"
COGNITO_ISSUER="${COGNITO_ISSUER:?Falta COGNITO_ISSUER}"
PUBLIC_HOST="${PUBLIC_HOST:-127.0.0.1}"
DIR="$(cd "$(dirname "$0")/task-definitions" && pwd)"

for file in "$DIR"/*.json; do
  tmp="$(mktemp)"
  sed -e "s/ACCOUNT_ID/${ACCOUNT_ID}/g" \
      -e "s|us-east-1_REPLACE|${COGNITO_ISSUER##*/}|g" \
      -e "s|https://cognito-idp.us-east-1.amazonaws.com/us-east-1_REPLACE|${COGNITO_ISSUER}|g" \
      -e "s/PUBLIC_HOST/${PUBLIC_HOST}/g" \
      "$file" > "$tmp"
  echo "Registrando $(basename "$file")..."
  aws ecs register-task-definition --region "$REGION" --cli-input-json "file://${tmp}"
  rm -f "$tmp"
done
