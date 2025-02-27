# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------

# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY

# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# These variables must be set when using this module.
# ---------------------------------------------------------------------------------------------------------------------

variable "aws_region" {
  description = "The AWS region in which all resources will be created."
  type        = string
  default     = "us-east-2"
}

variable "tags" {
  description = "(Optional) A map of tags to all resources that accept tags."
  type        = map(string)
  default = {
    Test        = "true"
    Environment = "dev"
    Repo        = "terraform-kubernetes-anyscale-foundation-modules",
    Example     = "aws/eks-public"
  }
}

variable "anyscale_s3_cors_rule" {
  description = <<-EOT
    (Optional) A map of CORS rules for the S3 bucket.

    Including here to override for Anyscale Staging.
  EOT
  type        = map(any)
  default = {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]
    allowed_origins = ["https://*.anyscale.com"]
    expose_headers  = []
  }
}
