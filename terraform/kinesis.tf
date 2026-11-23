# Stream de eventos de negocio (ADR-019): las marcas de asistencia entran aquí y varios
# consumidores las leen cada uno a su ritmo. La partition key es tenant_id (la pone el productor).
# 1 shard sobra para el volumen del lab; 24 h de retención permiten recuperar un consumidor caído.
resource "aws_kinesis_stream" "events" {
  name             = "${local.name}-events"
  shard_count      = 1
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

# Stream de telemetría de APIs (fase 5 de streaming): un registro técnico por request terminado,
# sin datos personales. Va separado de rrhh-events para que un pico de telemetría no atrase a los
# consumidores de negocio. Misma configuración que rrhh-events; la partition key es tenant_id.
resource "aws_kinesis_stream" "api_telemetry" {
  name             = "${local.name}-api-telemetry"
  shard_count      = 1
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = "alias/aws/kinesis"

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

locals {
  # Fase 1: solo asistencia publica sus marcas. Ausencias y contratos entran en la fase 6.
  # El código no toca Kinesis si RRHH_KINESIS_ENABLED no es "true"; AWS_REGION ya llega por sqs_env.
  kinesis_services = ["asistencia"]

  kinesis_env = {
    for k, s in local.services : k => contains(local.kinesis_services, k) ? [
      { name = "KINESIS_STREAM_NAME", value = aws_kinesis_stream.events.name },
      { name = "RRHH_KINESIS_ENABLED", value = "true" },
    ] : []
  }

  # Fase 5: piloto del filtro de telemetría en asistencia; los otros servicios se suman aquí,
  # uno por PR, y el dashboard los muestra solo (usa SEARCH por Servicio).
  # Con RRHH_TELEMETRY_ENABLED=true el servicio no arranca si TELEMETRY_STREAM_NAME viene vacío.
  telemetry_services = ["asistencia"]

  telemetry_env = {
    for k, s in local.services : k => contains(local.telemetry_services, k) ? [
      { name = "TELEMETRY_STREAM_NAME", value = aws_kinesis_stream.api_telemetry.name },
      { name = "RRHH_TELEMETRY_ENABLED", value = "true" },
    ] : []
  }
}
