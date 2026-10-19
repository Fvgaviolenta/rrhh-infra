resource "aws_sqs_queue" "events_dlq" {
  name                      = "${local.name}-notifications-events-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "events" {
  name                       = "${local.name}-notifications-events"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.events_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "events_dlq" {
  queue_url = aws_sqs_queue.events_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.events.arn]
  })
}

locals {
  # Una sola cola: contratos y ausencias publican (outbox), notifications consume.
  # El código no toca SQS si RRHH_SQS_ENABLED no es "true" (default false en application.yml).
  sqs_services = ["contratos", "ausencias", "notifications"]

  sqs_env = {
    for k, s in local.services : k => concat(
      [
        { name = "SQS_EVENTS_QUEUE_URL", value = aws_sqs_queue.events.url },
        { name = "AWS_REGION", value = var.region },
      ],
      contains(local.sqs_services, k) ? [{ name = "RRHH_SQS_ENABLED", value = "true" }] : [],
    )
  }
}
