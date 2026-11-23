# Consumidor 2 del stream rrhh-events (fase 4 de streaming): rrhh-atrasos lee las marcas de
# ENTRADA, detecta las que llegaron después del inicio del turno más TOLERANCIA_MINUTOS y envía
# asistencia.atraso.detectado a la cola rrhh-notifications-events, que notifications convierte
# en un aviso para la jefatura directa del trabajador.
# Corre fuera de la VPC: no toca MySQL ni Redis, y así no necesita NAT ni endpoints para llegar
# a Kinesis y a SQS. Usa LabRole (el lab no permite crear roles).
# Un lote que falla 3 veces (partido con bisect) va a la DLQ SQS. El mensaje de la DLQ no trae
# el registro, solo el shard y el rango de sequence numbers: para reprocesarlo hay que leerlo
# del stream antes de que venza la retención de 24 h.
# Orden de despliegue: notifications debe entender asistencia.atraso.detectado antes de aplicar
# este mapping; si no, cada aviso termina en rrhh-notifications-events-dlq tras 5 recepciones.

data "archive_file" "atrasos" {
  type        = "zip"
  source_file = "${path.module}/lambda/atrasos/handler.py"
  output_path = "${path.module}/.build/atrasos.zip"
}

resource "aws_cloudwatch_log_group" "atrasos" {
  name              = "/aws/lambda/${local.name}-atrasos"
  retention_in_days = 1
}

resource "aws_sqs_queue" "atrasos_dlq" {
  name                      = "${local.name}-atrasos-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_lambda_function" "atrasos" {
  function_name    = "${local.name}-atrasos"
  role             = local.lab_role_arn
  runtime          = "python3.13"
  handler          = "handler.lambda_handler"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.atrasos.output_path
  source_code_hash = data.archive_file.atrasos.output_base64sha256

  environment {
    variables = {
      SQS_EVENTS_QUEUE_URL = aws_sqs_queue.events.url
      # Minutos después del inicio del turno que todavía no cuentan como atraso.
      TOLERANCIA_MINUTOS = "5"
    }
  }

  depends_on = [aws_cloudwatch_log_group.atrasos]
}

resource "aws_lambda_event_source_mapping" "atrasos" {
  function_name                  = aws_lambda_function.atrasos.arn
  event_source_arn               = aws_kinesis_stream.events.arn
  starting_position              = "LATEST"
  batch_size                     = 100
  parallelization_factor         = 2
  bisect_batch_on_function_error = true
  maximum_retry_attempts         = 3

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.atrasos_dlq.arn
    }
  }

  # Solo marcas registradas de tipo ENTRADA; las salidas y las ediciones no invocan la función.
  filter_criteria {
    filter {
      pattern = jsonencode({
        data = {
          eventType = ["asistencia.marca.registrada"]
          payload   = { tipo = ["ENTRADA"] }
        }
      })
    }
  }
}
