resource "random_password" "db_password" {
  length  = 24
  special = false
}

resource "random_password" "grafana_password" {
  length  = 20
  special = false
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/comments-api/${var.environment}/db_user"
  type  = "String"
  value = "comments_user"
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/comments-api/${var.environment}/db_password"
  type  = "SecureString"
  value = random_password.db_password.result
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/comments-api/${var.environment}/db_name"
  type  = "String"
  value = "comments_db"
}

resource "aws_ssm_parameter" "grafana_password" {
  name  = "/comments-api/${var.environment}/grafana_password"
  type  = "SecureString"
  value = random_password.grafana_password.result
}
