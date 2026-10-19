locals {
  jdbc_url = "jdbc:mysql://${aws_instance.data.private_ip}:3306/${var.db_name}?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC"

  # Variables comunes; identity crea el esquema, los demás hacen baseline de Flyway.
  base_env = {
    for k, s in local.services : k => concat(
      [
        { name = "SPRING_PROFILES_ACTIVE", value = "cognito" },
        { name = "SERVER_PORT", value = tostring(s.port) },
        { name = "SPRING_DATASOURCE_URL", value = local.jdbc_url },
        { name = "SPRING_DATASOURCE_USERNAME", value = var.db_user },
        { name = "COGNITO_ISSUER", value = local.cognito_issuer },
      ],
      k == "identity" ? [] : [
        { name = "SPRING_FLYWAY_BASELINE_ON_MIGRATE", value = "true" },
        { name = "SPRING_FLYWAY_BASELINE_VERSION", value = "0" },
      ],
    )
  }

  extra_env = {
    identity     = []
    trabajadores = []
    contratos = [
      { name = "RRHH_TRABAJADORES_URL", value = "http://${local.alb_dns}" },
      { name = "RRHH_ASISTENCIA_URL", value = "http://${local.alb_dns}" },
    ]
    asistencia = []
    ausencias  = []
    notifications = [
      { name = "REDIS_HOST", value = aws_instance.data.private_ip },
      { name = "REDIS_PORT", value = "6379" },
    ]
  }

  # La contraseña va por secrets (SSM) o, con use_ssm_secrets = false, por environment; nunca por ambos.
  db_password_env = var.use_ssm_secrets ? [] : [{ name = "SPRING_DATASOURCE_PASSWORD", value = var.db_password }]
  db_password_secrets = var.use_ssm_secrets ? [
    { name = "SPRING_DATASOURCE_PASSWORD", valueFrom = aws_ssm_parameter.db_password.arn }
  ] : []

  # El nombre de un servicio ECS no se puede cambiar: service_names permite repetir el vivo al importar.
  service_names = { for k, s in local.services : k => lookup(var.service_names, k, "${local.name}-${k}") }

  other_services = { for k, s in local.services : k => s if k != "identity" }
}

resource "aws_cloudwatch_log_group" "svc" {
  for_each = local.services

  name              = "/ecs/${local.name}-${each.key}"
  retention_in_days = 1
}

resource "aws_ecs_cluster" "rrhh" {
  name = local.name
}

# Managed Instances es opcional: el lab puede no permitirlo (ver README).
resource "aws_ecs_capacity_provider" "managed" {
  count = var.enable_managed_instances ? 1 : 0

  name    = "${local.name}-managed"
  cluster = aws_ecs_cluster.rrhh.name

  managed_instances_provider {
    infrastructure_role_arn = local.lab_role_arn
    propagate_tags          = "CAPACITY_PROVIDER"

    instance_launch_template {
      ec2_instance_profile_arn = "arn:aws:iam::${local.account_id}:instance-profile/${var.instance_profile_name}"

      network_configuration {
        subnets         = local.subnet_ids
        security_groups = [aws_security_group.ecs.id]
      }

      storage_configuration {
        storage_size_gib = 30
      }
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "rrhh" {
  cluster_name = aws_ecs_cluster.rrhh.name

  capacity_providers = concat(
    ["FARGATE", "FARGATE_SPOT"],
    aws_ecs_capacity_provider.managed[*].name,
    var.extra_capacity_providers,
  )

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_ecs_task_definition" "svc" {
  for_each = local.services

  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = local.lab_role_arn
  task_role_arn            = local.lab_role_arn

  container_definitions = jsonencode([{
    name         = "${local.name}-${each.key}"
    image        = "${local.ecr_registry}/rrhh:${lookup(var.image_tag_suffix, each.key, each.key)}"
    essential    = true
    portMappings = [{ containerPort = each.value.port, protocol = "tcp" }]
    environment = concat(
      local.base_env[each.key],
      local.extra_env[each.key],
      local.sqs_env[each.key],
      local.db_password_env,
    )
    secrets = local.db_password_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.svc[each.key].name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

# identity va primero y espera estado estable; los otros cinco dependen de él (ver aws_ecs_service.svc).
resource "aws_ecs_service" "identity" {
  name                              = local.service_names["identity"]
  cluster                           = aws_ecs_cluster.rrhh.id
  task_definition                   = aws_ecs_task_definition.svc["identity"].arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120
  wait_for_steady_state             = true

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.svc["identity"].arn
    container_name   = "${local.name}-identity"
    container_port   = local.services.identity.port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http, aws_ecs_cluster_capacity_providers.rrhh, terraform_data.data_ready]
}

resource "aws_ecs_service" "svc" {
  for_each = local.other_services

  name                              = local.service_names[each.key]
  cluster                           = aws_ecs_cluster.rrhh.id
  task_definition                   = aws_ecs_task_definition.svc[each.key].arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 120
  wait_for_steady_state             = false

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.svc[each.key].arn
    container_name   = "${local.name}-${each.key}"
    container_port   = each.value.port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_ecs_service.identity, aws_lb_listener.http, aws_ecs_cluster_capacity_providers.rrhh]
}
