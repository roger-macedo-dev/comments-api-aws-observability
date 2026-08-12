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
