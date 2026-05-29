output "aws_lbc_iam_role_name" {
  description = "Name of the IAM role for the AWS Load Balancer Controller."
  value       = aws_iam_role.lbc.name
}

output "aws_lbc_iam_role_arn" {
  description = "ARN of the IAM role for the AWS Load Balancer Controller."
  value       = aws_iam_role.lbc.arn
}
