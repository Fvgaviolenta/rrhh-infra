#!/bin/bash
# User-data para la EC2 del cluster ECS (Learner Lab).
# Preferir AMI "Amazon ECS-Optimized Amazon Linux 2023".
# Si usas Amazon Linux 2023 genérica, descomenta el bloque de instalación.
set -euxo pipefail

CLUSTER_NAME="${ECS_CLUSTER_NAME:-rrhh-lab}"

mkdir -p /etc/ecs
cat >> /etc/ecs/ecs.config <<EOF
ECS_CLUSTER=${CLUSTER_NAME}
ECS_ENABLE_TASK_IAM_ROLE=true
ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs"]
EOF

# --- Solo si la AMI NO es ECS-Optimized ---
# dnf update -y
# dnf install -y docker
# systemctl enable --now docker
# dnf install -y ecs-init || true
# systemctl enable --now ecs || true

systemctl enable --now ecs || true

mkdir -p /var/lib/rrhh-mysql
chmod 755 /var/lib/rrhh-mysql
