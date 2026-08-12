output "instance_id" {
  description = "ID da instância EC2"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "IP público da instância"
  value       = aws_instance.app.public_ip
}

output "environment" {
  description = "Ambiente provisionado"
  value       = var.environment
}
