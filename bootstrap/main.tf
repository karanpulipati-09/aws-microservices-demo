variable "aws_account_id" {
  description = "AWS account ID used for the GitHub OIDC role and related resources."
  type        = string
  default     = "259851212818"
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format that is allowed to assume the OIDC role."
  type        = string
  default     = "karanpulipati-09/aws-microservices-demo"
}

variable "github_actions_role_name" {
  description = "Name of the GitHub Actions role used in CI/CD."
  type        = string
  default     = "github-actions-terraform"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name                 = var.github_actions_role_name
  max_session_duration = 7200

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "github_actions_terraform" {
  name = "${var.github_actions_role_name}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateManagement"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [
          "arn:aws:s3:::karan-tf-state-${var.aws_account_id}",
          "arn:aws:s3:::karan-tf-state-${var.aws_account_id}/*",
          "arn:aws:dynamodb:*:*:table/terraform-state-lock"
        ]
      },
      {
        Sid    = "VpcNetworking"
        Effect = "Allow"
        Action = [
          "ec2:Describe*",
          "ec2:CreateVpc",
          "ec2:DeleteVpc",
          "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet",
          "ec2:DeleteSubnet",
          "ec2:ModifySubnetAttribute",
          "ec2:CreateInternetGateway",
          "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway",
          "ec2:DetachInternetGateway",
          "ec2:CreateNatGateway",
          "ec2:DeleteNatGateway",
          "ec2:AllocateAddress",
          "ec2:ReleaseAddress",
          "ec2:AssociateRouteTable",
          "ec2:CreateRoute",
          "ec2:DeleteRoute",
          "ec2:CreateRouteTable",
          "ec2:DeleteRouteTable",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:DescribeTags"
        ]
        Resource = "*"
      },
      {
        Sid    = "LoadBalancingAndAutoscaling"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:*",
          "elasticloadbalancingv2:*",
          "autoscaling:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "EKSAndECRAndRDSAndSecrets",
        Effect = "Allow"
        Action = [
          "eks:*",
          "ecr:*",
          "rds:*",
          "secretsmanager:*"
        ]
        Resource = "*"
      },
      {
        Sid    = "IamRoleAndIdentitySetup",
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PassRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListPolicyVersions",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint",
          "iam:AddClientIDToOpenIDConnectProvider",
          "iam:CreateServiceLinkedRole",
          "iam:GetServiceLinkedRoleDeletionStatus"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_terraform.arn
}
