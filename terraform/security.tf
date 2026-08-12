resource "aws_security_group" "app" {
  name        = "comments-api-${var.environment}"
  description = "SG da instancia comments-api - so porta 80 exposta, resto interno ao Docker"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP publico (nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Saida liberada (docker pull, apt, SSM, etc)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "comments-api-${var.environment}"
  }
}
