# Consumidor 1 del stream rrhh-events (fase 3 de streaming): rrhh-stream-metrics cuenta las
# marcas por minuto de llegada, empresa y tipo, y las publica en CloudWatch con logs EMF.
# La misma función lee también rrhh-api-telemetry (fase 5), con un segundo mapping: cuenta los
# requests por servicio, clase de status y empresa, y la latencia por servicio y ruta.
# Corre fuera de la VPC: no toca MySQL ni Redis, y así no necesita NAT ni endpoints para llegar
# a Kinesis y a CloudWatch. Usa LabRole (el lab no permite crear roles).
# Un lote que falla 3 veces (partido con bisect) va a la DLQ SQS. El mensaje de la DLQ no trae
# el registro, solo el shard y el rango de sequence numbers: para reprocesarlo hay que leerlo
# del stream antes de que venza la retención de 24 h.

data "archive_file" "stream_metrics" {
  type        = "zip"
  source_file = "${path.module}/lambda/stream_metrics/handler.py"
  output_path = "${path.module}/.build/stream-metrics.zip"
}

resource "aws_cloudwatch_log_group" "stream_metrics" {
  name              = "/aws/lambda/${local.name}-stream-metrics"
  retention_in_days = 1
}

resource "aws_sqs_queue" "stream_metrics_dlq" {
  name                      = "${local.name}-stream-metrics-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_lambda_function" "stream_metrics" {
  function_name    = "${local.name}-stream-metrics"
  role             = local.lab_role_arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.stream_metrics.output_path
  source_code_hash = data.archive_file.stream_metrics.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.stream_metrics]
}

resource "aws_lambda_event_source_mapping" "stream_metrics" {
  function_name                  = aws_lambda_function.stream_metrics.arn
  event_source_arn               = aws_kinesis_stream.events.arn
  starting_position              = "LATEST"
  batch_size                     = 100
  parallelization_factor         = 2
  bisect_batch_on_function_error = true
  maximum_retry_attempts         = 3

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_metrics_dlq.arn
    }
  }

  # Solo los tipos que este consumidor cuenta; los demás registros no invocan la función.
  filter_criteria {
    filter {
      pattern = jsonencode({
        data = { eventType = ["asistencia.marca.registrada", "asistencia.editada"] }
      })
    }
  }
}

# Segundo mapping (fase 5): la misma función lee la telemetría de APIs, con los mismos valores y
# la misma DLQ que el mapping de rrhh-events.
resource "aws_lambda_event_source_mapping" "stream_metrics_telemetry" {
  function_name                  = aws_lambda_function.stream_metrics.arn
  event_source_arn               = aws_kinesis_stream.api_telemetry.arn
  starting_position              = "LATEST"
  batch_size                     = 100
  parallelization_factor         = 2
  bisect_batch_on_function_error = true
  maximum_retry_attempts         = 3

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.stream_metrics_dlq.arn
    }
  }

  # Solo los registros de request; cualquier otra cosa en el stream no invoca la función.
  filter_criteria {
    filter {
      pattern = jsonencode({
        data = { tipo = ["api.request"] }
      })
    }
  }
}
