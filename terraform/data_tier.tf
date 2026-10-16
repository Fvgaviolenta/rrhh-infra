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
  })

  tags = {
    Name = "${local.name}-data"
  }

  depends_on = [aws_ssm_parameter.db_password]

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
