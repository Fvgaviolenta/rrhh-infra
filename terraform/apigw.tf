resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${local.name}-vpc-link"
  subnet_ids         = local.subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = concat(["http://localhost:5173", local.amplify_url], var.extra_cors_origins)
    allow_headers  = ["authorization", "content-type", "x-empresa-slug", "x-request-id"]
    allow_methods  = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    expose_headers = ["x-request-id"]
    max_age        = 3600
  }
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id           = aws_apigatewayv2_api.http.id
  name             = "${local.name}-cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = local.cognito_issuer
    audience = [aws_cognito_user_pool_client.spa.id]
  }
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.http.arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.main.id
  payload_format_version = "1.0"
  timeout_milliseconds   = 30000
}

locals {
  # El resolver de tenant se consulta antes de iniciar sesión; todo lo demás exige JWT.
  api_routes = {
    "GET /api/v1/tenants/resolver" = { jwt = false }
    "ANY /api/v1/{proxy+}"         = { jwt = true }
  }
}

resource "aws_apigatewayv2_route" "routes" {
  for_each = local.api_routes

  api_id             = aws_apigatewayv2_api.http.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.alb.id}"
  authorization_type = each.value.jwt ? "JWT" : "NONE"
  authorizer_id      = each.value.jwt ? aws_apigatewayv2_authorizer.jwt.id : null
}

# Throttling real en default_route_settings, no stage variables (que no limitan nada).
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = 30
    throttling_burst_limit = 60
  }
}
