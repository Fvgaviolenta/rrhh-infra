locals {
  api_base = aws_apigatewayv2_api.http.api_endpoint
}

output "http_api_url" {
  description = "URL base del HTTP API (VITE_API_GATEWAY_URL)"
  value       = local.api_base
}

output "amplify_url" {
  description = "URL de la rama de Amplify"
  value       = local.amplify_url
}

output "cognito_user_pool_id" {
  description = "ID del user pool de Cognito"
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "ID del app client público de Cognito (VITE_COGNITO_CLIENT_ID)"
  value       = aws_cognito_user_pool_client.spa.id
}

output "cognito_issuer" {
  description = "Issuer JWT del pool (COGNITO_ISSUER de los servicios)"
  value       = local.cognito_issuer
}

output "cognito_domain_url" {
  description = "URL base del dominio de Cognito para login federado"
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "alb_dns" {
  description = "DNS del ALB interno"
  value       = local.alb_dns
}

output "sqs_events_queue_url" {
  description = "URL de la cola SQS de eventos"
  value       = aws_sqs_queue.events.url
}

output "data_private_ip" {
  description = "IP privada de la EC2 de datos (MySQL y Redis)"
  value       = aws_instance.data.private_ip
}

output "next_steps" {
  description = "Cómo publicar el build de Vite en Amplify"
  value       = "Sube el zip de dist/ con: aws amplify create-deployment --app-id ${aws_amplify_app.frontend.id} --branch-name ${var.amplify_branch} (luego curl -T dist.zip <zipUploadUrl> y aws amplify start-deployment). Detalle en terraform/README.md."
}

output "vite_env" {
  description = "Las variables VITE_* que lee el frontend al compilar"
  value = {
    VITE_API_GATEWAY_URL   = local.api_base
    VITE_API_IDENTITY      = "${local.api_base}/api/v1"
    VITE_API_TRABAJADORES  = "${local.api_base}/api/v1"
    VITE_API_CONTRATOS     = "${local.api_base}/api/v1"
    VITE_API_ASISTENCIA    = "${local.api_base}/api/v1"
    VITE_API_AUSENCIAS     = "${local.api_base}/api/v1"
    VITE_API_NOTIFICATIONS = "${local.api_base}/api/v1"
    VITE_COGNITO_REGION    = var.region
    VITE_COGNITO_CLIENT_ID = aws_cognito_user_pool_client.spa.id
    # cognitoAuth.ts exige el pool o el issuer; oidcConfig.ts usa el issuer y el dominio para el login y el logout.
    VITE_COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
    VITE_COGNITO_ISSUER       = local.cognito_issuer
    VITE_COGNITO_DOMAIN       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
  }
}
