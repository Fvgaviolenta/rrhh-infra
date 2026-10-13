variables {
  db_password = "x"
}

mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      id         = "vpc-0123456789abcdef0"
      cidr_block = "172.31.0.0/16"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/LabRole"
    }
  }

  mock_data "aws_subnets" {
    defaults = {
      ids = ["subnet-0aaa0000000000001", "subnet-0bbb0000000000002"]
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/rrhh-alb-internal/0123456789abcdef"
      dns_name = "internal-rrhh-alb-internal-1.us-east-1.elb.amazonaws.com"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/rrhh-tg/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/rrhh-alb-internal/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_ssm_parameter" {
    defaults = {
      arn = "arn:aws:ssm:us-east-1:123456789012:parameter/rrhh/db/password"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      private_ip = "172.31.88.7"
    }
  }
}

run "six_services_with_fixed_ports" {
  command = plan

  assert {
    condition     = length(local.services) == 6 && local.services.identity.port == 8081 && local.services.notifications.port == 8086
    error_message = "locals.services debe tener 6 servicios con puertos 8081-8086"
  }
}

run "two_subnets_when_not_provided" {
  command = plan

  assert {
    condition     = length(local.subnet_ids) == 2
    error_message = "sin service_subnet_ids se descubren exactamente 2 subnets"
  }
}

run "ssh_rule_absent_when_cidr_empty" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.data_ssh) == 0
    error_message = "con ssh_allowed_cidr vacío no debe abrirse el 22"
  }
}

run "ssh_rule_present_when_cidr_set" {
  command = plan

  variables {
    ssh_allowed_cidr = "203.0.113.10/32"
  }

  assert {
    condition     = length([for r in aws_vpc_security_group_ingress_rule.data_ssh : r]) == 1
    error_message = "con CIDR definido debe existir exactamente una regla 22"
  }
}

run "user_data_does_not_embed_the_db_password" {
  command = plan

  variables {
    db_password = "pw-secreta-de-prueba"
  }

  assert {
    condition     = !strcontains(aws_instance.data.user_data, "pw-secreta-de-prueba") && aws_ssm_parameter.db_password.type == "SecureString"
    error_message = "la contraseña vive en SSM SecureString y no en el user-data"
  }
}

run "data_sg_opens_only_mysql_and_redis_to_ecs" {
  command = plan

  assert {
    condition     = toset([for r in aws_vpc_security_group_ingress_rule.data_from_ecs : r.from_port]) == toset([3306, 6379])
    error_message = "rrhh-sg-data solo acepta 3306 y 6379 desde rrhh-sg-ecs"
  }
}

run "alb_rules_unique_priorities_and_404_default" {
  command = plan

  assert {
    condition     = length(local.alb_rules) == 21 && length(distinct([for r in local.alb_rules : r.priority])) == 21
    error_message = "el JSON debe tener 21 reglas con prioridades únicas"
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].fixed_response[0].status_code == "404"
    error_message = "el listener debe responder 404 por defecto"
  }
}

run "platform_subroutes_and_horas_extra_are_routed" {
  command = plan

  assert {
    condition = alltrue([
      contains([for r in local.alb_rules : r.path], "/api/v1/horas-extra*"),
      contains([for r in local.alb_rules : r.path], "/api/v1/plataforma/tenants/*/trabajadores*"),
      contains([for r in local.alb_rules : r.path], "/api/v1/plataforma/tenants/*/contratos*"),
      contains([for r in local.alb_rules : r.path], "/api/v1/plataforma/tenants/*/ausencias*"),
      contains([for r in local.alb_rules : r.path], "/api/v1/plataforma/tenants/*/notificaciones*"),
    ])
    error_message = "faltan reglas de horas-extra o de plataforma por servicio"
  }
}

run "six_target_groups_with_actuator_health" {
  command = plan

  assert {
    condition     = length(aws_lb_target_group.svc) == 6 && alltrue([for k, t in aws_lb_target_group.svc : t.health_check[0].path == "/actuator/health" && t.target_type == "ip"])
    error_message = "6 target groups tipo ip con health check /actuator/health"
  }
}

run "events_queue_has_dlq_with_five_receives" {
  command = plan

  override_resource {
    target          = aws_sqs_queue.events_dlq
    override_during = plan
    values = {
      arn = "arn:aws:sqs:us-east-1:123456789012:rrhh-notifications-events-dlq"
    }
  }

  assert {
    condition     = jsondecode(aws_sqs_queue.events.redrive_policy).maxReceiveCount == 5
    error_message = "la cola debe redirigir a la DLQ tras 5 recepciones"
  }

  assert {
    condition     = aws_sqs_queue.events.visibility_timeout_seconds == 60 && aws_sqs_queue.events.receive_wait_time_seconds == 20 && aws_sqs_queue.events.message_retention_seconds == 345600 && aws_sqs_queue.events_dlq.message_retention_seconds == 1209600
    error_message = "visibility 60 s, long polling 20 s, retención 4 días y DLQ 14 días"
  }
}

run "google_idp_absent_when_unset" {
  command = plan

  assert {
    condition     = length(aws_cognito_identity_provider.google) == 0 && toset(aws_cognito_user_pool_client.spa.supported_identity_providers) == toset(["COGNITO"])
    error_message = "sin credenciales de Google no hay proveedor ni se lista en el client"
  }
}

run "google_idp_present_when_set" {
  command = plan

  variables {
    google_client_id     = "id-de-prueba"
    google_client_secret = "secret-de-prueba"
  }

  assert {
    condition     = length(aws_cognito_identity_provider.google) == 1 && contains(aws_cognito_user_pool_client.spa.supported_identity_providers, "Google")
    error_message = "con credenciales debe existir Google"
  }
}

run "pool_has_tenant_id_and_public_client" {
  command = plan

  assert {
    condition     = contains([for s in aws_cognito_user_pool.main.schema : s.name], "tenant_id") && !contains([for s in aws_cognito_user_pool.main.schema : s.name], "tenat_id") && aws_cognito_user_pool_client.spa.generate_secret == false
    error_message = "el pool necesita custom:tenant_id (no tenat_id) y el client no lleva secret"
  }
}

run "amplify_spa_rewrite_serves_index" {
  command = plan

  assert {
    condition     = one([for r in aws_amplify_app.frontend.custom_rule : r if r.target == "/index.html"]).status == "404-200"
    error_message = "la SPA necesita la reescritura 404-200 hacia /index.html"
  }
}

run "cluster_has_only_fargate_by_default" {
  command = plan

  assert {
    condition     = toset(aws_ecs_cluster_capacity_providers.rrhh.capacity_providers) == toset(["FARGATE", "FARGATE_SPOT"])
    error_message = "sin enable_managed_instances el cluster solo usa FARGATE y FARGATE_SPOT"
  }
}

run "no_iam_roles_are_created" {
  command = plan

  assert {
    condition     = length(keys(aws_ecs_task_definition.svc)) == 6 && alltrue([for k, t in aws_ecs_task_definition.svc : t.execution_role_arn == "arn:aws:iam::123456789012:role/LabRole" && t.task_role_arn == "arn:aws:iam::123456789012:role/LabRole"])
    error_message = "todas las tareas usan LabRole y no se crean roles"
  }
}

run "contratos_receives_integration_urls_and_notifications_redis" {
  command = apply

  assert {
    condition     = length([for e in jsondecode(aws_ecs_task_definition.svc["contratos"].container_definitions)[0].environment : e if e.name == "RRHH_TRABAJADORES_URL" || e.name == "RRHH_ASISTENCIA_URL"]) == 2
    error_message = "contratos necesita las URLs de trabajadores y asistencia"
  }

  assert {
    condition     = length([for e in jsondecode(aws_ecs_task_definition.svc["notifications"].container_definitions)[0].environment : e if e.name == "REDIS_HOST" || e.name == "SQS_EVENTS_QUEUE_URL"]) == 2
    error_message = "notifications necesita REDIS_HOST y SQS_EVENTS_QUEUE_URL"
  }
}

run "db_password_comes_from_ssm_secret" {
  command = apply

  assert {
    condition = alltrue([for k, t in aws_ecs_task_definition.svc :
      length([for c in jsondecode(t.container_definitions) : c if length([for x in c.secrets : x if x.name == "SPRING_DATASOURCE_PASSWORD"]) == 1 && length([for e in c.environment : e if e.name == "SPRING_DATASOURCE_PASSWORD"]) == 0]) == 1
    ])
    error_message = "la contraseña llega por secrets (SSM), no por environment"
  }
}

run "services_use_public_ip_and_wait_on_identity" {
  command = plan

  assert {
    condition     = alltrue([for s in concat([aws_ecs_service.identity], values(aws_ecs_service.svc)) : s.network_configuration[0].assign_public_ip == true && s.health_check_grace_period_seconds == 120]) && length(aws_ecs_service.svc) == 5
    error_message = "los 6 servicios con IP pública y grace period 120"
  }

  assert {
    condition     = aws_ecs_service.identity.wait_for_steady_state == true && alltrue([for k, s in aws_ecs_service.svc : s.wait_for_steady_state == false])
    error_message = "solo identity espera estado estable"
  }
}

run "client_cannot_write_security_claims" {
  command = plan

  assert {
    condition     = length([for a in aws_cognito_user_pool_client.spa.write_attributes : a if startswith(a, "custom:")]) == 0 && length(aws_cognito_user_pool_client.spa.read_attributes) == 6
    error_message = "el client no puede escribir custom:role, custom:tenant_id ni los demás claims; solo lectura"
  }
}

run "db_password_goes_to_environment_only_without_ssm" {
  command = apply

  variables {
    use_ssm_secrets = false
    db_password     = "pw-de-prueba"
  }

  assert {
    condition = alltrue([for k, t in aws_ecs_task_definition.svc :
      length(jsondecode(t.container_definitions)[0].secrets) == 0 && length([for e in jsondecode(t.container_definitions)[0].environment : e if e.name == "SPRING_DATASOURCE_PASSWORD"]) == 1
    ])
    error_message = "con use_ssm_secrets = false la contraseña va solo por environment"
  }
}

run "api_has_two_routes_jwt_except_resolver" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_route.routes) == 2 && aws_apigatewayv2_route.routes["GET /api/v1/tenants/resolver"].authorization_type == "NONE" && aws_apigatewayv2_route.routes["ANY /api/v1/{proxy+}"].authorization_type == "JWT"
    error_message = "solo resolver sin autenticación; el resto con JWT"
  }
}

run "stage_throttling_is_real_not_stage_variables" {
  command = plan

  assert {
    condition     = aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit == 30 && aws_apigatewayv2_stage.default.default_route_settings[0].throttling_burst_limit == 60 && aws_apigatewayv2_stage.default.auto_deploy == true
    error_message = "stage $default con rate 30, burst 60 y auto deploy"
  }
}

run "outputs_expose_the_vite_variables_the_frontend_reads" {
  command = plan

  assert {
    condition = alltrue([for k in [
      "VITE_API_GATEWAY_URL", "VITE_API_IDENTITY", "VITE_API_TRABAJADORES", "VITE_API_CONTRATOS",
      "VITE_API_ASISTENCIA", "VITE_API_AUSENCIAS", "VITE_API_NOTIFICATIONS", "VITE_COGNITO_REGION",
      "VITE_COGNITO_CLIENT_ID", "VITE_COGNITO_USER_POOL_ID", "VITE_COGNITO_ISSUER", "VITE_COGNITO_DOMAIN",
    ] : contains(keys(output.vite_env), k)])
    error_message = "cognitoAuth.ts y oidcConfig.ts exigen el pool o el issuer y el dominio además de las 9 variables de la guía"
  }
}

run "google_idp_absent_when_secret_missing" {
  command = plan

  variables {
    google_client_id = "id-de-prueba"
  }

  assert {
    condition     = length(aws_cognito_identity_provider.google) == 0 && !contains(aws_cognito_user_pool_client.spa.supported_identity_providers, "Google")
    error_message = "con id pero sin secret no se crea el proveedor Google"
  }
}

run "ecs_services_can_call_the_internal_alb" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_ecs.from_port == 80
    error_message = "contratos llama al ALB desde rrhh-sg-ecs: el ALB debe aceptar el puerto 80 desde ese SG"
  }
}

run "subnet_guard_fails_with_zero_subnets" {
  command = plan

  override_data {
    target = data.aws_subnets.chosen
    values = {
      ids = []
    }
  }

  expect_failures = [terraform_data.subnet_guard]
}

run "subnet_guard_fails_with_six_subnets" {
  command = plan

  override_data {
    target = data.aws_subnets.chosen
    values = {
      ids = ["subnet-1", "subnet-2", "subnet-3", "subnet-4", "subnet-5", "subnet-6"]
    }
  }

  expect_failures = [terraform_data.subnet_guard]
}
