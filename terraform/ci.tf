# Usuario IAM usado pelo pipeline de CD.
#
# O runner do GitHub Actions atua como control node do Ansible: descobre a
# instancia (inventario dinamico), abre sessao SSM no lugar de SSH, transfere
# arquivos pelo bucket de apoio e le os segredos do Parameter Store para
# renderizar o .env. As permissoes abaixo cobrem exatamente esses quatro papeis.
#
# Evolucao registrada no roadmap: trocar chave estatica por OIDC, eliminando
# credencial de longa duracao nos secrets do repositorio.

resource "aws_iam_user" "ci" {
  name = "comments-api-${var.environment}-ci"
}

resource "aws_iam_access_key" "ci" {
  user = aws_iam_user.ci.name
}

data "aws_iam_policy_document" "ci" {
  # Inventario dinamico: descobre a instancia pela tag Name.
  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # Conexao sem SSH: abre e encerra sessoes do Session Manager.
  statement {
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:StartSession",
      "ssm:TerminateSession",
      "ssm:ResumeSession",
      "ssm:GetConnectionStatus",
    ]
    resources = ["*"]
  }

  # Leitura dos segredos para renderizar o .env, restrita ao prefixo do ambiente.
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/comments-api/${var.environment}/*"]
  }

  # Registra qual imagem esta implantada, para o rollback saber a que voltar.
  # O estado do deploy vive fora do host: se a instancia for recriada, a
  # informacao sobrevive.
  statement {
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/comments-api/${var.environment}/imagem_atual"]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }

  # Bucket de apoio que o plugin aws_ssm usa para transferir arquivos.
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.ssm_bucket}/*"]
  }

  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:aws:s3:::${var.ssm_bucket}"]
  }
}

resource "aws_iam_user_policy" "ci" {
  name   = "cd-pipeline"
  user   = aws_iam_user.ci.name
  policy = data.aws_iam_policy_document.ci.json
}

output "ci_access_key_id" {
  description = "Access key do usuario de CI — configurar como secret no GitHub"
  value       = aws_iam_access_key.ci.id
}

output "ci_secret_access_key" {
  description = "Secret key do usuario de CI — configurar como secret no GitHub"
  value       = aws_iam_access_key.ci.secret
  sensitive   = true
}
