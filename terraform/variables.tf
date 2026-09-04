variable "environment" {
  description = "Nome do ambiente (dev, test, prod)"
  type        = string
}

variable "instance_type" {
  description = "Tipo da instância EC2"
  type        = string
  default     = "t3.micro"
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR da subnet pública"
  type        = string
  default     = "10.20.1.0/24"
}

variable "use_rds" {
  description = "Se true, provisiona RDS; se false, Postgres roda em container"
  type        = bool
  default     = false
}

variable "region" {
  description = "Regiao AWS"
  type        = string
  default     = "us-east-2"
}

variable "ssm_bucket" {
  description = "Bucket usado pelo plugin de conexao aws_ssm para transferir arquivos"
  type        = string
  default     = "comments-api-tfstate-428521271992"
}

variable "repositorio_github" {
  description = "Repositorio autorizado a assumir a role via OIDC (dono/nome)"
  type        = string
  default     = "roger-macedo-dev/comments-api-aws-observability"
}

variable "criar_provedor_oidc" {
  description = "O provedor OIDC e unico por conta AWS; criar em apenas um workspace"
  type        = bool
  default     = false
}
