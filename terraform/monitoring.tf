locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# SNS topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  count    = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "alarms" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action = "SNS:Publish"
      Resource = aws_sns_topic.alerts.arn
    }]
  })
}

# ALB 5xx errors (aggregate) — adjust dimensions to target specific ALB/TargetGroup if needed
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.name_prefix}-alb-5xx"
  alarm_description   = "ALB target 5xx errors exceed threshold"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# RDS replica lag alarm (seconds) — only relevant when read replicas exist
resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  alarm_name          = "${local.name_prefix}-rds-replica-lag"
  alarm_description   = "RDS replica lag > 100ms"
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0.1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# EKS pod restart rate: recommend Prometheus alerts via kube-prometheus-stack.
# Create a CloudWatch alarm placeholder for Container Insights if enabled.
resource "aws_cloudwatch_metric_alarm" "eks_pod_restarts" {
  alarm_name          = "${local.name_prefix}-eks-pod-restarts"
  alarm_description   = "EKS pod restart rate (placeholder). Prefer Prometheus alerts."
  namespace           = "ContainerInsights"
  metric_name         = "PodRestartCount"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# CloudTrail to monitor terraform state S3 bucket (data events)
resource "aws_cloudtrail" "tfstate_trail" {
  name                          = "${local.name_prefix}-tfstate-trail"
  is_multi_region_trail         = false
  include_global_service_events = false
  enable_logging                = true
}

resource "aws_cloudtrail_event_selector" "s3_data_events" {
  trail_name = aws_cloudtrail.tfstate_trail.name

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type = "AWS::S3::Object"
      values = ["arn:aws:s3:::${var.tfstate_bucket}/"]
    }
  }
}

# Send CloudTrail notifications to SNS via CloudWatch Events (EventBridge)
resource "aws_cloudwatch_event_rule" "tfstate_s3_put" {
  name        = "${local.name_prefix}-tfstate-s3-put"
  description = "Capture PutObject/DeleteObject events on terraform state bucket"
  event_pattern = jsonencode({
    "source": ["aws.s3"],
    "detail-type": ["AWS API Call via CloudTrail"],
    "detail": {
      "eventSource": ["s3.amazonaws.com"],
      "eventName": ["PutObject", "DeleteObject"] ,
      "requestParameters": {"bucketName": [var.tfstate_bucket]}
    }
  })
}

resource "aws_cloudwatch_event_target" "notify_sns" {
  rule      = aws_cloudwatch_event_rule.tfstate_s3_put.name
  target_id = "sendToSNS"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_permission" "allow_events" {
  statement_id  = "AllowEventsToPutTargets"
  action        = "events:PutEvents"
  principal     = "events.amazonaws.com"
  rule          = aws_cloudwatch_event_rule.tfstate_s3_put.name
}
