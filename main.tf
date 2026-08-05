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