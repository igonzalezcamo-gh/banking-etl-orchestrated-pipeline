resource "aws_s3_bucket" "data_lake" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- IAM role for Glue ---
resource "aws_iam_role" "glue_role" {
  name = "${var.project_name}-glue-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}

# AWS standard managed policy for Glue
resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Scoped policy: access limited to OUR bucket only (not all of S3)
resource "aws_iam_role_policy" "glue_s3_access" {
  name = "${var.project_name}-glue-s3-access"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
      }
    ]
  })
}

# --- Glue Catalog Database ---
resource "aws_glue_catalog_database" "banking_db" {
  name = var.glue_database_name
}

# --- Crawler: raw zone ---
resource "aws_glue_crawler" "raw_crawler" {
  name          = "${var.project_name}-raw-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.banking_db.name
  table_prefix  = "raw_"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.id}/raw/paysim/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior  = "UPDATE_IN_DATABASE"
  }
}

# --- Crawler: curated zone ---
resource "aws_glue_crawler" "curated_crawler" {
  name          = "${var.project_name}-curated-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.banking_db.name
  table_prefix  = "curated_"

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.id}/curated/paysim/"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior  = "UPDATE_IN_DATABASE"
  }
}

# --- Upload the PySpark script to S3 ---
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.data_lake.id
  key    = "scripts/transform_transactions.py"
  source = "${path.module}/glue_jobs/transform_transactions.py"
  etag   = filemd5("${path.module}/glue_jobs/transform_transactions.py")
}

# --- Glue Job ---
resource "aws_glue_job" "transform_job" {
  name     = "${var.project_name}-transform-job"
  role_arn = aws_iam_role.glue_role.arn

  glue_version      = "4.0"
  worker_type       = "G.1X"
  number_of_workers = 2

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.data_lake.id}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--database_name" = aws_glue_catalog_database.banking_db.name
    "--table_name"    = "raw_paysim"
    "--output_path"   = "s3://${aws_s3_bucket.data_lake.id}/curated/paysim/"
    "--job-language"  = "python"
  }
}

# --- IAM role for Step Functions ---
resource "aws_iam_role" "step_functions_role" {
  name = "${var.project_name}-stepfunctions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })
}

# Permissions: allow Step Functions to start/monitor Glue crawlers and jobs
resource "aws_iam_role_policy" "step_functions_glue_access" {
  name = "${var.project_name}-stepfunctions-glue-access"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler",
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns",
          "glue:BatchStopJobRun",
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = templatefile("${path.module}/step_functions/pipeline.asl.json", {
    raw_crawler_name     = aws_glue_crawler.raw_crawler.name
    curated_crawler_name = aws_glue_crawler.curated_crawler.name
    glue_job_name        = aws_glue_job.transform_job.name
  })
}

# --- IAM role for EventBridge to trigger Step Functions ---
resource "aws_iam_role" "eventbridge_role" {
  name = "${var.project_name}-eventbridge-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "eventbridge_start_execution" {
  name = "${var.project_name}-eventbridge-start-execution"
  role = aws_iam_role.eventbridge_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.pipeline.arn
      }
    ]
  })
}

# --- Scheduling rule: runs daily at 3 AM UTC ---
resource "aws_cloudwatch_event_rule" "daily_schedule" {
  name                = "${var.project_name}-daily-trigger"
  description         = "Triggers the banking ETL pipeline every day at 3 AM UTC"
  schedule_expression = "cron(0 3 * * ? *)"
}

resource "aws_cloudwatch_event_target" "pipeline_target" {
  rule     = aws_cloudwatch_event_rule.daily_schedule.name
  arn      = aws_sfn_state_machine.pipeline.arn
  role_arn = aws_iam_role.eventbridge_role.arn
}

# --- SNS topic for pipeline failure notifications ---
resource "aws_sns_topic" "pipeline_alerts" {
  name = "${var.project_name}-pipeline-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- CloudWatch alarm: triggers if the state machine execution fails ---
resource "aws_cloudwatch_metric_alarm" "pipeline_failure" {
  alarm_name          = "${var.project_name}-pipeline-failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ExecutionsFailed"
  namespace           = "AWS/States"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alarm when the banking ETL pipeline execution fails"
  alarm_actions       = [aws_sns_topic.pipeline_alerts.arn]

  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline.arn
  }
}