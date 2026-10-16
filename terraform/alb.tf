locals {
  # alb/listener-rules.json es la única fuente de las reglas de path del ALB.
  alb_rules = jsondecode(file("${path.module}/../alb/listener-rules.json"))
  alb_dns   = aws_lb.internal.dns_name
}

resource "aws_lb" "internal" {
  name                       = "${local.name}-alb-internal"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = local.subnet_ids
  security_groups            = [aws_security_group.alb.id]
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "svc" {
  for_each = local.services

  name        = "${local.name}-tg-${each.key}"
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.internal.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = jsonencode({ codigo = 404, mensaje = "Ruta no enrutada" })
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "path" {
  for_each = { for r in local.alb_rules : tostring(r.priority) => r }

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc[replace(each.value.tg, "${local.name}-tg-", "")].arn
  }

  condition {
    path_pattern {
      values = [each.value.path]
    }
  }
}
