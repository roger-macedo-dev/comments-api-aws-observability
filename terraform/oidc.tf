# Autenticacao do pipeline sem credencial de longa duracao.
#
# Em vez de uma chave de acesso guardada nos secrets, o GitHub Actions apresenta
# um token de identidade assinado por ele mesmo; a AWS confia nesse emissor e
# devolve credenciais temporarias, validas por minutos.
#
# A condicao sobre "sub" e o coracao do arranjo: sem ela, qualquer repositorio
# do GitHub poderia assumir esta role. Aqui so o repositorio deste projeto, e
# somente quando o job roda no Environment correspondente ao ambiente.

data "aws_caller_identity" "atual" {}

locals {
  emissor_github = "token.actions.githubusercontent.com"
  arn_provedor   = "arn:aws:iam::${data.aws_caller_identity.atual.account_id}:oidc-provider/${local.emissor_github}"
}

# O provedor OIDC e unico por conta AWS, nao por ambiente. Criado apenas no
# workspace que tiver a flag ligada; os demais apenas o referenciam pelo ARN.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.criar_provedor_oidc ? 1 : 0

  url             = "https://${local.emissor_github}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "confianca_github" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.arn_provedor]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.emissor_github}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Amarra ao repositorio e ao Environment: a role de dev nao pode ser
    # assumida por um job de prod, nem o contrario.
    condition {
      test     = "StringEquals"
      variable = "${local.emissor_github}:sub"
      values   = ["repo:${var.repositorio_github}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "github" {
  name               = "comments-api-${var.environment}-github"
  assume_role_policy = data.aws_iam_policy_document.confianca_github.json
}

# Mesma politica do usuario IAM: as permissoes necessarias nao mudam, o que
# muda e a forma de autenticar.
resource "aws_iam_role_policy" "github" {
  name   = "cd-pipeline"
  role   = aws_iam_role.github.id
  policy = data.aws_iam_policy_document.ci.json
}

output "github_role_arn" {
  description = "ARN da role assumida pelo pipeline via OIDC"
  value       = aws_iam_role.github.arn
}
