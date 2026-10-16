locals {
  name         = var.name_prefix
  account_id   = data.aws_caller_identity.current.account_id
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  lab_role_arn = data.aws_iam_role.lab.arn

  # Puertos fijos 8081-8086, los mismos de alb/listener-rules.json y de los task definitions.
  services = {
    identity      = { port = 8081, rol = "identity", cpu = 512, memory = 1024 }
    trabajadores  = { port = 8082, cpu = 512, memory = 1024 }
    contratos     = { port = 8083, cpu = 512, memory = 1024 }
    asistencia    = { port = 8084, cpu = 512, memory = 1024 }
    ausencias     = { port = 8085, cpu = 512, memory = 1024 }
    notifications = { port = 8086, cpu = 512, memory = 1024 }
  }
}
