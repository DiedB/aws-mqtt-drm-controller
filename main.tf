terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  aws_iot_certificate_arn = "arn:aws:iot:eu-west-1:530676788171:cert/efdce7afb5992158251a3d25dd2fedefb4844f93b9b3be36e1afcd347858aafa"
}

# IoT Core Policy for Shelly device
resource "aws_iot_policy" "shelly_device_policy" {
  name = "shelly-device-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iot:Connect"
        ]
        Resource = [
          "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:client/${var.client_id}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:Subscribe"
        ]
        Resource = [
          "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/shellies/*",
          "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${var.client_id}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iot:Publish"
        ]
        Resource = [
          "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/shellies/announce",
          "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${var.client_id}/*"
        ]
      }
    ]
  })
}

# IoT Core Thing for Shelly device
resource "aws_iot_thing" "shelly_device" {
  name = "shelly-drm-controller"
}

# Attach policy to certificate
resource "aws_iot_policy_attachment" "shelly_device_policy_attachment" {
  policy = aws_iot_policy.shelly_device_policy.name
  target = local.aws_iot_certificate_arn
}

# Attach certificate to thing
resource "aws_iot_thing_principal_attachment" "shelly_device_cert_attachment" {
  principal = local.aws_iot_certificate_arn
  thing     = aws_iot_thing.shelly_device.name
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Get IoT endpoint
data "aws_iot_endpoint" "endpoint" {
  endpoint_type = "iot:Data-ATS"
}

# IAM role for Lambda execution
resource "aws_iam_role" "lambda_execution_role" {
  name = "solar-controller-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda to publish to IoT Core
resource "aws_iam_policy" "lambda_iot_policy" {
  name        = "solar-controller-lambda-iot-policy"
  description = "Policy for Lambda to publish to IoT Core"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iot:Publish"
        ]
        Resource = [
          "arn:aws:iot:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${var.client_id}/command/switch:0"
        ]
      }
    ]
  })
}

# Attach IoT policy to Lambda role
resource "aws_iam_role_policy_attachment" "lambda_iot_policy_attachment" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_iot_policy.arn
}

# Attach basic Lambda execution policy
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Build the Go binary for ARM64 and create deployment package
resource "null_resource" "build_lambda" {
  triggers = {
    source_code_hash = filemd5("${path.module}/lambda/main.go")
  }

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ${path.module}/lambda/dist
      cd ${path.module}/lambda
      GOOS=linux GOARCH=arm64 go build -o dist/bootstrap main.go
    EOT
  }
}

# Data source to get the hash of the built zip file
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "${path.module}/lambda/dist/lambda.zip"
  source_file = "${path.module}/lambda/dist/bootstrap"

  depends_on = [null_resource.build_lambda]
}

# Lambda function
resource "aws_lambda_function" "solar_controller" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "solar-controller"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = ["arm64"]
  timeout          = 15
  memory_size      = 128
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      IOT_ENDPOINT     = data.aws_iot_endpoint.endpoint.endpoint_address
      SHELLY_CLIENT_ID = var.client_id
    }
  }

  depends_on = [data.archive_file.lambda_zip]
}

# EventBridge rule to trigger Lambda every hour
resource "aws_cloudwatch_event_rule" "hourly_trigger" {
  name                = "solar-controller-hourly-trigger"
  description         = "Trigger solar controller Lambda every hour"
  schedule_expression = "cron(0 * * * ? *)"
}

# EventBridge target to invoke Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule = aws_cloudwatch_event_rule.hourly_trigger.name
  arn  = aws_lambda_function.solar_controller.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.solar_controller.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.hourly_trigger.arn
}
