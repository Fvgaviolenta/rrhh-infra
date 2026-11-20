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
