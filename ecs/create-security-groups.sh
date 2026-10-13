#!/bin/bash
# Security groups en la VPC por defecto. Imprime IDs para .env.aws
# Uso: VPC_ID=vpc-xxx VPC_CIDR=172.31.0.0/16 ./create-security-groups.sh
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
VPC_ID="${VPC_ID:?Falta VPC_ID}"
VPC_CIDR="${VPC_CIDR:-172.31.0.0/16}"

sg() {
  local name="$1" desc="$2"
  aws ec2 create-security-group --group-name "$name" --description "$desc" \
    --vpc-id "$VPC_ID" --region "$REGION" --query GroupId --output text
}

# Quita el egress All/0.0.0.0/0 que AWS pone por defecto.
revoke_all_egress() {
  aws ec2 revoke-security-group-egress --group-id "$1" --region "$REGION" \
    --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null || true
}

egress_https_dns() {
  aws ec2 authorize-security-group-egress --group-id "$1" --region "$REGION" \
    --ip-permissions \
      "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" \
      "IpProtocol=udp,FromPort=53,ToPort=53,IpRanges=[{CidrIp=0.0.0.0/0}]" \
      "IpProtocol=tcp,FromPort=53,ToPort=53,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null
}

SG_ALB_INTERNAL="$(sg rrhh-sg-alb-internal "ALB interno HTTP API VPC Link")"
SG_FARGATE_MS="$(sg rrhh-sg-fargate-ms "Fargate microservicios 8081-8086")"
SG_ALB_PUBLIC="$(sg rrhh-sg-alb-public "ALB publico frontend")"
SG_FRONTEND="$(sg rrhh-sg-frontend "Fargate frontend 3000")"
SG_DATOS="$(sg rrhh-sg-datos "EC2 MySQL Redis RabbitMQ")"

# --- Inbound ---
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB_INTERNAL" --region "$REGION" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=${VPC_CIDR}}]" >/dev/null

for port in 8081 8082 8083 8084 8085 8086; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_FARGATE_MS" --region "$REGION" \
    --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${SG_ALB_INTERNAL}}]" >/dev/null
done

aws ec2 authorize-security-group-ingress --group-id "$SG_ALB_PUBLIC" --region "$REGION" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null

aws ec2 authorize-security-group-ingress --group-id "$SG_FRONTEND" --region "$REGION" \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=${SG_ALB_PUBLIC}}]" >/dev/null

for port in 3306 6379 5672; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_DATOS" --region "$REGION" \
    --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${SG_FARGATE_MS}}]" >/dev/null
done

# --- Outbound (reemplaza All) ---
revoke_all_egress "$SG_ALB_INTERNAL"
aws ec2 authorize-security-group-egress --group-id "$SG_ALB_INTERNAL" --region "$REGION" \
  --ip-permissions "IpProtocol=tcp,FromPort=8081,ToPort=8086,UserIdGroupPairs=[{GroupId=${SG_FARGATE_MS}}]" >/dev/null
# El VPC Link usa este mismo SG: sin salida al puerto 80, API Gateway responde 503.
aws ec2 authorize-security-group-egress --group-id "$SG_ALB_INTERNAL" --region "$REGION" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,UserIdGroupPairs=[{GroupId=${SG_ALB_INTERNAL}}]" >/dev/null

revoke_all_egress "$SG_ALB_PUBLIC"
aws ec2 authorize-security-group-egress --group-id "$SG_ALB_PUBLIC" --region "$REGION" \
  --ip-permissions "IpProtocol=tcp,FromPort=3000,ToPort=3000,UserIdGroupPairs=[{GroupId=${SG_FRONTEND}}]" >/dev/null

revoke_all_egress "$SG_FARGATE_MS"
for port in 3306 6379 5672; do
  aws ec2 authorize-security-group-egress --group-id "$SG_FARGATE_MS" --region "$REGION" \
    --ip-permissions "IpProtocol=tcp,FromPort=${port},ToPort=${port},UserIdGroupPairs=[{GroupId=${SG_DATOS}}]" >/dev/null
done
egress_https_dns "$SG_FARGATE_MS"

revoke_all_egress "$SG_FRONTEND"
egress_https_dns "$SG_FRONTEND"

revoke_all_egress "$SG_DATOS"
egress_https_dns "$SG_DATOS"

echo "SG_ALB_INTERNAL=${SG_ALB_INTERNAL}"
echo "SG_FARGATE_MS=${SG_FARGATE_MS}"
echo "SG_ALB_PUBLIC=${SG_ALB_PUBLIC}"
echo "SG_FRONTEND=${SG_FRONTEND}"
echo "SG_DATOS=${SG_DATOS}"
