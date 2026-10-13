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
