# Offline Terraform graph tests. These IDs exist only in the mock provider.
mock_provider "aws" {
  mock_data "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:us-east-1:123456789012:repository/assessment", repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/assessment" }
  }
  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-0123456789abcdef0" } }
  mock_data "aws_ssm_parameter" { defaults = { value = "ami-0123456789abcdef0" } }
}
variables {
  region            = "us-east-1"
  environment       = "staging"
  subnet_id         = "subnet-0123456789abcdef0"
  reviewer_cidr     = "192.0.2.1/32"
  repository_name   = "assessment"
  initial_tag       = "1.0.0"
  github_repo       = "example/assessment"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}
run "staging" {
  command = plan
  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == 14 && aws_instance.app.metadata_options[0].http_tokens == "required"
    error_message = "Log retention and IMDSv2 are required."
  }
}
run "production" {
  command = plan
  variables { environment = "production" }
  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/assessment/production/app" && length(aws_security_group.app.ingress) == 1
    error_message = "Expected isolated production logs and one ingress rule."
  }
}
run "reject_world_ingress" {
  command = plan
  variables { reviewer_cidr = "0.0.0.0/0" }
  expect_failures = [var.reviewer_cidr]
}
