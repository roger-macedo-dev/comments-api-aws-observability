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
  description = <<-TEXTO
    Identificacao do repositorio no claim "sub" do token do GitHub, no formato
    dono@id/repositorio@id. Os numeros sao os identificadores internos e nao
    mudam se o dono ou o repositorio forem renomeados — amarrar a eles impede
    que alguem registre um nome abandonado e herde esta confianca.
  TEXTO
  type        = string
  default     = "roger-macedo-dev@223531064/comments-api-aws-observability@1332110395"
}

variable "criar_provedor_oidc" {
  description = <<-TEXTO
    O provedor OIDC e unico por conta AWS e deve ser criado por um unico
    workspace. Consequencia operacional: o workspace que o cria precisa ser o
    primeiro a subir e o ultimo a ser destruido — hoje, dev. Para operar apenas
    prod, ligue esta flag no tfvars de prod.
  TEXTO
  type        = bool
  default     = false
}
