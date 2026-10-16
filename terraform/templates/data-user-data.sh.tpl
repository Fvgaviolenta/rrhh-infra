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

unset DB_PASSWORD
