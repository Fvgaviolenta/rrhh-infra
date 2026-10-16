data "aws_caller_identity" "current" {}

data "aws_vpc" "default" {
  default = true
}

# LabRole ya existe en la cuenta del lab; Terraform no crea roles ni políticas IAM.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

data "aws_subnets" "chosen" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "availability-zone"
    values = ["${var.region}a", "${var.region}b"]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  subnet_ids = length(var.service_subnet_ids) > 0 ? var.service_subnet_ids : data.aws_subnets.chosen.ids
}

# ALB, VPC Link y servicios necesitan exactamente 2 subnets en AZ distintas.
resource "terraform_data" "subnet_guard" {
  input = local.subnet_ids

  lifecycle {
    precondition {
      condition     = length(local.subnet_ids) == 2
      error_message = "Se requieren exactamente 2 subnets; define service_subnet_ids o revisa las subnets por defecto de ${var.region}a y ${var.region}b."
    }
  }
}

# Security groups: sin reglas en línea, todas son recursos aparte.
resource "aws_security_group" "alb" {
  name        = "${local.name}-sg-alb-internal"
  description = "ALB interno: entrada solo desde el VPC Link"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "vpc_link" {
  name        = "${local.name}-sg-vpc-link"
  description = "VPC Link del HTTP API: salida hacia el ALB interno"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "ecs" {
  name        = "${local.name}-sg-ecs"
  description = "Servicios ECS Fargate"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "data" {
  name        = "${local.name}-sg-data"
  description = "EC2 de datos: MySQL y Redis"
  vpc_id      = data.aws_vpc.default.id
}

locals {
  service_port_min = min([for s in local.services : s.port]...)
  service_port_max = max([for s in local.services : s.port]...)

  data_ports = {
    mysql = 3306
    redis = 6379
  }

  # Con restrict_egress = true los SG ecs y data solo salen a HTTPS (ECR, SSM, logs) y DNS.
  world_egress = var.restrict_egress ? {
    https   = { port = 443, protocol = "tcp" }
    dns_tcp = { port = 53, protocol = "tcp" }
    dns_udp = { port = 53, protocol = "udp" }
  } : {}
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpc_link" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.vpc_link.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  description                  = "HTTP desde el VPC Link"
}

# contratos llama a http://<dns del ALB> desde los servicios ECS (RRHH_TRABAJADORES_URL y RRHH_ASISTENCIA_URL).
resource "aws_vpc_security_group_ingress_rule" "alb_from_ecs" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ecs.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  description                  = "HTTP desde los servicios ECS"
}

resource "aws_vpc_security_group_egress_rule" "ecs_to_alb" {
  count = var.restrict_egress ? 1 : 0

  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  description                  = "HTTP hacia el ALB interno"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ecs" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ecs.id
  ip_protocol                  = "tcp"
  from_port                    = local.service_port_min
  to_port                      = local.service_port_max
  description                  = "Hacia los servicios ECS"
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_alb" {
  security_group_id            = aws_security_group.vpc_link.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  description                  = "HTTP hacia el ALB interno"
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.service_port_min
  to_port                      = local.service_port_max
  description                  = "Servicios desde el ALB interno"
}

resource "aws_vpc_security_group_ingress_rule" "data_from_ecs" {
  for_each = local.data_ports

  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.ecs.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "${each.key} desde los servicios ECS"
}

resource "aws_vpc_security_group_ingress_rule" "data_ssh" {
  count = var.ssh_allowed_cidr == "" ? 0 : 1

  security_group_id = aws_security_group.data.id
  cidr_ipv4         = var.ssh_allowed_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "SSH desde el CIDR autorizado"
}

resource "aws_vpc_security_group_egress_rule" "ecs_open" {
  count = var.restrict_egress ? 0 : 1

  security_group_id = aws_security_group.ecs.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Salida total"
}

resource "aws_vpc_security_group_egress_rule" "ecs_to_data" {
  for_each = var.restrict_egress ? local.data_ports : {}

  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.data.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "${each.key} hacia la EC2 de datos"
}

resource "aws_vpc_security_group_egress_rule" "ecs_world" {
  for_each = local.world_egress

  security_group_id = aws_security_group.ecs.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Salida ${each.key}"
}

resource "aws_vpc_security_group_egress_rule" "data_open" {
  count = var.restrict_egress ? 0 : 1

  security_group_id = aws_security_group.data.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Salida total"
}

resource "aws_vpc_security_group_egress_rule" "data_world" {
  for_each = local.world_egress

  security_group_id = aws_security_group.data.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = each.value.protocol
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Salida ${each.key}"
}
