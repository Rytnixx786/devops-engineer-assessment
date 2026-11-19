terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.0" } }
  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
variable "region" { type = string }
provider "aws" { region = var.region }

variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "Choose staging or production."
  }
}
variable "subnet_id" { type = string }
variable "reviewer_cidr" {
  type = string
  validation {
    condition     = can(cidrnetmask(var.reviewer_cidr)) && !endswith(var.reviewer_cidr, "/0")
    error_message = "Use a restricted reviewer IPv4 CIDR."
  }
}
variable "repository_name" { type = string }
variable "initial_tag" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.initial_tag))
    error_message = "Supply a published immutable image tag."
  }
}
variable "github_repo" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "Use owner/repo."
  }
}
variable "oidc_provider_arn" { type = string }
variable "instance_type" {
  type    = string
  default = "t3.micro"
}
locals { name = "assessment-${var.environment}" }
data "aws_subnet" "target" { id = var.subnet_id }
data "aws_ecr_repository" "app" { name = var.repository_name }
data "aws_ssm_parameter" "ami" { name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" }
resource "aws_cloudwatch_log_group" "app" {
  name              = "/assessment/${var.environment}/app"
  retention_in_days = 14
}
resource "aws_security_group" "app" {
  name   = local.name
  vpc_id = data.aws_subnet.target.vpc_id
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.reviewer_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }] })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy" "runtime" {
  role = aws_iam_role.instance.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = data.aws_ecr_repository.app.arn },
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.app.arn}:*" }
  ] })
}
resource "aws_iam_instance_profile" "app" {
  name = local.name
  role = aws_iam_role.instance.name
}
resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  metadata_options { http_tokens = "required" }
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    deploy = filebase64("${path.module}/../scripts/deploy.sh"), repo = data.aws_ecr_repository.app.repository_url,
    region = var.region, env = var.environment, group = aws_cloudwatch_log_group.app.name, tag = var.initial_tag
  })
  depends_on = [aws_iam_role_policy.runtime, aws_iam_role_policy_attachment.ssm]
  tags       = { Name = local.name, Environment = var.environment }
}
resource "aws_ssm_document" "release" {
  name          = "${local.name}-release"
  document_type = "Command"
  content = jsonencode({
    schemaVersion = "2.2", parameters = { tag = { type = "String", allowedPattern = "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" } },
    mainSteps     = [{ action = "aws:runShellScript", name = "deploy", inputs = { runCommand = ["/usr/local/sbin/assessment-deploy '{{ tag }}'"] } }]
  })
}
resource "aws_iam_role" "release" {
  name = "${local.name}-release"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = var.oidc_provider_arn },
    Condition = { StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com", "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main" } }
  }] })
}
resource "aws_iam_role_policy" "release" {
  role = aws_iam_role.release.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken", "ssm:GetCommandInvocation"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"], Resource = data.aws_ecr_repository.app.arn },
    { Effect = "Allow", Action = "ssm:SendCommand", Resource = [aws_instance.app.arn, aws_ssm_document.release.arn] }
  ] })
}
output "instance_id" { value = aws_instance.app.id }
output "public_ip" { value = aws_instance.app.public_ip }
output "role_arn" { value = aws_iam_role.release.arn }
output "ssm_document" { value = aws_ssm_document.release.name }
