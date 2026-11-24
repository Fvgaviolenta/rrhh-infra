# Correos de la consola de plataforma (ADR-020, S7): notifications publica cada mensaje de la plataforma en
# este tema con el atributo `destinatario`. Las suscripciones email no las crea Terraform: notifications crea
# una por destinatario, con filter policy por `destinatario`, la primera vez que le escribe; la persona la
# confirma desde el correo de AWS. Una suscripción sin filtro recibiría los correos de todas las empresas.
# SES no se usa: el lab responde AccessDeniedException.
resource "aws_sns_topic" "correos" {
  name = "${local.name}-correos"
}

locals {
  sns_services = ["notifications"]

  sns_env = {
    for k, s in local.services : k => contains(local.sns_services, k) ? [
      { name = "SNS_CORREOS_TOPIC_ARN", value = aws_sns_topic.correos.arn },
      # Copia de cada mensaje al AdminPlataforma: las empresas de prueba usan correos ficticios y así se ve que salen.
      { name = "SNS_CORREOS_COPIA", value = var.platform_admin_email },
    ] : []
  }
}
