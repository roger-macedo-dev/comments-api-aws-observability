data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "comments-api-${var.environment}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "read_parameters" {
  statement {
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:us-east-2:*:parameter/comments-api/${var.environment}/*"
    ]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.us-east-2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "read_parameters" {
  name   = "read-ssm-parameters"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.read_parameters.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "comments-api-${var.environment}-instance"
  role = aws_iam_role.instance.name
}
