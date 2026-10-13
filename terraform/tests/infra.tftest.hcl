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
