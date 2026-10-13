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
