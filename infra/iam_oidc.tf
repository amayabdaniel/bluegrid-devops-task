# =============================================================================
# GitHub Actions OIDC: zero static AWS credentials in GitHub
# =============================================================================
# - Creates the OIDC provider for token.actions.githubusercontent.com (idempotent
#   per account; if you already have one, replace this with `data` lookups).
# - Defines a deploy role assumable ONLY by this repo, ONLY from the listed
#   branches, with permissions limited to ssm:SendCommand on this one instance.
# - The CD workflow assumes this role with `aws-actions/configure-aws-credentials`.
# =============================================================================

# Thumbprint is no longer required when using GitHub's official OIDC provider
# (AWS now validates against the well-known IAM trust store). thumbprint_list is
# kept as required-but-unused for backwards compatibility.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Lock the trust to this repo + only the listed refs (branches)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for r in var.github_deploy_refs : "repo:${var.github_repo}:ref:${r}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name_prefix          = "${var.project}-gh-deploy-"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  description          = "Assumed by GitHub Actions CD via OIDC. Scoped to ${var.github_repo}."
  max_session_duration = 3600
}

# Minimum permissions: invoke RunShellScript on THIS instance only,
# read the result, and read instance metadata.
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid     = "InvokeShellScriptOnThisHost"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.gs.id}",
    ]
  }

  statement {
    sid       = "PollCommandResults"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadInstance"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "github_deploy" {
  name_prefix = "${var.project}-gh-deploy-"
  policy      = data.aws_iam_policy_document.github_deploy.json
}

resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = aws_iam_policy.github_deploy.arn
}
