# Dashboard de streaming (fase 3): marcas por minuto que publica rrhh-stream-metrics (EMF,
# namespace RRHH/Streaming), iterator age del stream y de la Lambda (si vuelve a 0, el
# consumidor alcanzó al productor) y mensajes en las DLQ.
# Fase 5: requests, errores 4xx/5xx y latencia p95 por servicio, que rrhh-stream-metrics saca del
# stream rrhh-api-telemetry. Usan SEARCH por la dimensión Servicio, así que un servicio que se
# sume a local.telemetry_services aparece solo. Los 429 del throttling los da el API Gateway y no
# llegan al servicio: se ven en "Respuestas 4xx del API Gateway". Todos los widgets a 60 s.

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
            ["AWS/Kinesis", "GetRecords.IteratorAgeMilliseconds", "StreamName", aws_kinesis_stream.api_telemetry.name],
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
      merge(local.streaming_widget, {
        x = 0
        y = 12
        properties = {
          title   = "Requests por minuto"
          region  = var.region
          view    = "timeSeries"
          period  = 60
          metrics = [[{ expression = "SEARCH('{RRHH/Streaming,Servicio} MetricName=\"Requests\"', 'Sum', 60)", id = "e1" }]]
        }
      }),
      merge(local.streaming_widget, {
        x = 12
        y = 12
        properties = {
          title   = "Errores 4xx y 5xx"
          region  = var.region
          view    = "timeSeries"
          period  = 60
          metrics = [[{ expression = "SEARCH('{RRHH/Streaming,Servicio,StatusClass} MetricName=\"Requests\" (StatusClass=\"4xx\" OR StatusClass=\"5xx\")', 'Sum', 60)", id = "e1" }]]
        }
      }),
      merge(local.streaming_widget, {
        x = 0
        y = 18
        properties = {
          title   = "Latencia p95 por servicio"
          region  = var.region
          view    = "timeSeries"
          period  = 60
          metrics = [[{ expression = "SEARCH('{RRHH/Streaming,Servicio} MetricName=\"Latencia\"', 'p95', 60)", id = "e1" }]]
        }
      }),
      merge(local.streaming_widget, {
        x = 12
        y = 18
        properties = {
          title  = "Respuestas 4xx del API Gateway"
          region = var.region
          view   = "timeSeries"
          period = 60
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "4xx", "ApiId", aws_apigatewayv2_api.http.id],
          ]
        }
      }),
    ]
  })
}
