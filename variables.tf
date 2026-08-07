variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Name of the S3 bucket for the orchestrated pipeline"
  type        = string
  default     = "banking-etl-orchestrated-2026"
}

variable "glue_database_name" {
  description = "Name of the Glue Data Catalog database"
  type        = string
  default     = "banking_etl_orchestrated_db"
}

variable "project_name" {
  description = "Project name used as prefix for resource naming"
  type        = string
  default     = "banking-etl-orchestrated"
}

variable "alert_email" {
  description = "Email address to receive pipeline failure alerts"
  type        = string
}