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
}
