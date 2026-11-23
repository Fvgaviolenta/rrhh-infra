# Dashboard de streaming (fase 3): marcas por minuto que publica rrhh-stream-metrics (EMF,
# namespace RRHH/Streaming), iterator age del stream y de la Lambda (si vuelve a 0, el
# consumidor alcanzó al productor) y mensajes en las dos DLQ. Todos los widgets a 60 s.

locals {
  streaming_widget = {
    type   = "metric"
    width  = 12
    height = 6
  }
}

resource "aws_cloudwatch_dashboard" "streaming" {
  dashboard_name = "${local.name}-streaming"

  dashboard_body = jsonencode({
    widgets = [
      merge(local.streaming_widget, {
        x = 0
        y = 0
        properties = {
          title  = "Marcas por minuto"
          region = var.region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["RRHH/Streaming", "Eventos", "EventType", "asistencia.marca.registrada"],
          ]
        }
      }),
      merge(local.streaming_widget, {
        x = 12
        y = 0
        properties = {
          title  = "Eventos por tipo"
          region = var.region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["RRHH/Streaming", "Eventos", "EventType", "asistencia.marca.registrada"],
            ["RRHH/Streaming", "Eventos", "EventType", "asistencia.editada"],
            ["RRHH/Streaming", "EventosInvalidos"],
          ]
        }
      }),
      merge(local.streaming_widget, {
        x = 0
        y = 6
        properties = {
          title  = "Iterator age"
          region = var.region
          view   = "timeSeries"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds", "StreamName", aws_kinesis_stream.events.name],
            ["AWS/Lambda", "IteratorAge", "FunctionName", aws_lambda_function.stream_metrics.function_name],
          ]
        }
      }),
      merge(local.streaming_widget, {
        x = 12
        y = 6
        properties = {
          title  = "Mensajes en las DLQ"
          region = var.region
          view   = "timeSeries"
          period = 60
          stat   = "Maximum"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.events_dlq.name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.stream_metrics_dlq.name],
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.atrasos_dlq.name],
          ]
        }
      }),
    ]
  })
}
