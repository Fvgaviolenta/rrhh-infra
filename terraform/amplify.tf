# Amplify sin repositorio: el build de Vite se sube como zip (ver README).
resource "aws_amplify_app" "frontend" {
  name     = "${local.name}-frontend"
  platform = "WEB"

  # Reescritura de SPA: cualquier ruta sin archivo sirve index.html.
  custom_rule {
    source = "/<*>"
    target = "/index.html"
    status = "404-200"
  }
}

resource "aws_amplify_branch" "staging" {
  app_id            = aws_amplify_app.frontend.id
  branch_name       = var.amplify_branch
  stage             = "PRODUCTION"
  enable_auto_build = false
}

locals {
  amplify_url = "https://${var.amplify_branch}.${aws_amplify_app.frontend.default_domain}"
}
