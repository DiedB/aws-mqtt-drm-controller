output "iot_endpoint" {
  description = "IoT Core endpoint"
  value       = data.aws_iot_endpoint.endpoint.endpoint_address
}
