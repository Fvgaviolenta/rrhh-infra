data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "data" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.data_instance_type
  subnet_id              = var.data_subnet_id != "" ? var.data_subnet_id : try(local.subnet_ids[0], null) # sin subnets falla subnet_guard, no un índice inválido
  vpc_security_group_ids = [aws_security_group.data.id]
  iam_instance_profile   = var.instance_profile_name
  key_name               = var.data_key_name == "" ? null : var.data_key_name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/data-user-data.sh.tpl", {
    region            = var.region
    db_name           = var.db_name
    db_user           = var.db_user
    db_password_param = aws_ssm_parameter.db_password.name
    ready_param       = local.data_ready_param
  })

  tags = {
    Name = "${local.name}-data"
  }

  # Las reglas de salida son recursos aparte: sin ellas el script de arranque no llega a SSM ni a Docker Hub
  # (Terraform quita la salida abierta que AWS agrega a un security group nuevo).
  depends_on = [
    aws_ssm_parameter.db_password,
    aws_vpc_security_group_egress_rule.data_open,
    aws_vpc_security_group_egress_rule.data_world,
  ]

  # El parámetro público apunta siempre al AMI más nuevo; sin esto, un AMI nuevo reemplaza la
  # instancia y se pierde el volumen de MySQL que vive en su disco raíz.
  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "data" {
  count = var.associate_data_eip ? 1 : 0

  instance = aws_instance.data.id
  domain   = "vpc"
}

locals {
  data_ready_param = "/${local.name}/data/ready"
}

# La EC2 publica este parámetro cuando MySQL acepta conexiones y Redis responde; aquí se espera y se borra.
# Los servicios ECS dependen de este recurso para no arrancar antes que la base.
resource "terraform_data" "data_ready" {
  count = var.wait_for_data ? 1 : 0

  triggers_replace = aws_instance.data.id

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]

    environment = {
      AWS_REGION  = var.region
      READY_PARAM = local.data_ready_param
    }

    command = <<-EOT
      for i in $(seq 1 90); do
        if aws ssm get-parameter --region "$AWS_REGION" --name "$READY_PARAM" >/dev/null 2>&1; then
          aws ssm delete-parameter --region "$AWS_REGION" --name "$READY_PARAM" >/dev/null
          echo "MySQL y Redis listos"
          exit 0
        fi
        sleep 10
      done
      echo "MySQL y Redis no avisaron en 15 minutos; revisa /var/log/cloud-init-output.log en la EC2 de datos" >&2
      exit 1
    EOT
  }
}
