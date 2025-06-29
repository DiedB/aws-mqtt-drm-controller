variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "eu-west-1"
}

variable "client_id" {
  description = "Client ID for the Shelly device"
  type        = string
}