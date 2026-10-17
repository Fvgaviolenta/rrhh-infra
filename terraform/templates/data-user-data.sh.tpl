#!/bin/bash
# EC2 de datos: MySQL y Redis en Docker. La contraseña se lee de SSM, no está en este script.
set -euo pipefail

dnf install -y docker
systemctl enable --now docker

DB_PASSWORD=""
for attempt in $(seq 1 10); do
  DB_PASSWORD=$(aws ssm get-parameter --region "${region}" --name "${db_password_param}" \
    --with-decryption --query Parameter.Value --output text) && break
  sleep 15
done
[ -n "$DB_PASSWORD" ] || { echo "no se pudo leer la contraseña de SSM" >&2; exit 1; }

docker volume create mysql_data

docker run -d --name mysql --restart unless-stopped \
  -e MYSQL_RANDOM_ROOT_PASSWORD=yes \
  -e MYSQL_DATABASE="${db_name}" \
  -e MYSQL_USER="${db_user}" \
  -e MYSQL_PASSWORD="$DB_PASSWORD" \
  -v mysql_data:/var/lib/mysql \
  -p 3306:3306 \
  mysql:8.4 --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci

docker run -d --name redis --restart unless-stopped \
  -p 6379:6379 \
  redis:7-alpine

# Avisa a Terraform cuando MySQL acepta conexiones con el usuario de la aplicación y Redis responde.
READY=""
for attempt in $(seq 1 60); do
  if docker exec mysql mysql -u"${db_user}" -p"$DB_PASSWORD" "${db_name}" -e "select 1" >/dev/null 2>&1 \
    && [ "$(docker exec redis redis-cli ping 2>/dev/null)" = "PONG" ]; then
    READY=1
    break
  fi
  sleep 5
done
[ -n "$READY" ] || { echo "MySQL o Redis no respondieron a tiempo" >&2; exit 1; }

aws ssm put-parameter --region "${region}" --name "${ready_param}" --type String --value ready --overwrite

unset DB_PASSWORD
