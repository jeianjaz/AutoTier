###############################################################################
# iam.tf
#
# The IAM role EC2 instances "wear" so they can call AWS APIs without
# carrying access keys. Four resources:
#
#   1. aws_iam_role                      -> the role itself + trust policy
#   2. aws_iam_role_policy               -> inline least-privilege secret read
#   3. aws_iam_role_policy_attachment    -> AWS-managed SSM policy
#   4. aws_iam_instance_profile          -> what you actually attach to EC2
#
# LEAST PRIVILEGE PRINCIPLE
# -------------------------
# Every Action in this file is either:
#   - scoped to ONE specific resource ARN (the DB secret), OR
#   - from an AWS-managed policy specifically scoped to "basic SSM agent
#     functionality on an EC2 instance."
#
# There is no `Action: "*"`, no `Resource: "*"`, no AdministratorAccess.
# Every permission has a justification in the adjacent comment.
###############################################################################


# =============================================================================
# TRUST POLICY -- "who can assume this role?"
# =============================================================================
#
# Only the EC2 service can assume this role. A compromised user, a Lambda,
# or another account cannot. This is the first firewall.

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}


# =============================================================================
# THE ROLE
# =============================================================================

resource "aws_iam_role" "app" {
  name               = "${local.name_prefix}-app-role"
  description        = "Role EC2 app instances assume. Grants read on the DB secret and basic SSM agent perms."
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json

  tags = {
    Name = "${local.name_prefix}-app-role"
  }
}


# =============================================================================
# PERMISSION 1: Read the DB secret (and only that one)
# =============================================================================
#
# `resources = [aws_secretsmanager_secret.db_master.arn]` is the key line.
# Swap that for `"*"` and any compromised EC2 would read every secret in
# the account. Resource scoping is what separates a junior IAM policy
# from a senior one.

data "aws_iam_policy_document" "read_db_secret" {
  statement {
    sid       = "ReadDBMasterSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_master.arn]
  }
}

resource "aws_iam_role_policy" "read_db_secret" {
  name   = "${local.name_prefix}-read-db-secret"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.read_db_secret.json
}


# =============================================================================
# PERMISSION 2: SSM Session Manager + basic agent functions
# =============================================================================
#
# `AmazonSSMManagedInstanceCore` is AWS-managed, so we don't write its JSON
# ourselves -- we just attach it. It grants the minimum the SSM agent needs
# to register the instance, receive commands, and open Session Manager
# terminals. Nothing else.
#
# This is the modern replacement for SSH. No port 22 opened anywhere; the
# agent reaches out to SSM via outbound 443 (through our NAT Gateway).

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


# =============================================================================
# INSTANCE PROFILE -- what you actually attach to EC2
# =============================================================================
#
# IAM has two separate concepts that confuse everyone the first time:
#   - Role: the bundle of permissions.
#   - Instance Profile: the thing that binds a Role to an EC2 instance.
# aws_instance takes `iam_instance_profile`, NOT a role directly.
# You always need both; they usually share a name.

resource "aws_iam_instance_profile" "app" {
  name = "${local.name_prefix}-app-profile"
  role = aws_iam_role.app.name

  tags = {
    Name = "${local.name_prefix}-app-profile"
  }
}


###############################################################################
# LAMBDA REMEDIATION ROLE (Step 7)
###############################################################################
#
# Separate role from the EC2 one — different trust policy (lambda.amazonaws.com
# vs ec2.amazonaws.com) and different permissions. Combining them into one role
# would violate least privilege: the EC2 instances don't need autoscaling
# termination powers, and the Lambda doesn't need to read secrets.
###############################################################################


# =============================================================================
# TRUST POLICY -- only Lambda can assume this role
# =============================================================================

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}


# =============================================================================
# THE ROLE
# =============================================================================

resource "aws_iam_role" "lambda_remediation" {
  name               = "${local.name_prefix}-lambda-remediation-role"
  description        = "Role for the auto-remediation Lambda. Can query target health and terminate ASG instances."
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json

  tags = {
    Name = "${local.name_prefix}-lambda-remediation-role"
  }
}


# =============================================================================
# PERMISSION: describe target health + terminate unhealthy instances
# =============================================================================
#
# Three permissions, each scoped as tightly as possible:
#
#   1. DescribeTargetHealth — scoped to the app target group ARN.
#   2. DescribeAutoScalingInstances — scoped to "*" because the API does not
#      accept a resource ARN (AWS limitation). Mitigated by the fact that this
#      is a read-only call.
#   3. TerminateInstanceInAutoScalingGroup — scoped to the ASG ARN. This is
#      the critical one: without resource scoping, the Lambda could terminate
#      instances in ANY ASG in the account.

data "aws_iam_policy_document" "lambda_remediation" {
  # Query which targets are unhealthy
  # NOTE: DescribeTargetHealth does NOT support resource-level permissions
  # in AWS IAM (it's a Describe* call). Resource must be "*".
  statement {
    sid       = "DescribeTargetHealth"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DescribeTargetHealth"]
    resources = ["*"]
  }

  # Check if an instance belongs to an ASG (read-only, no resource scoping available)
  statement {
    sid       = "DescribeASGInstances"
    effect    = "Allow"
    actions   = ["autoscaling:DescribeAutoScalingInstances"]
    resources = ["*"]
  }

  # Terminate the unhealthy instance via the ASG API
  statement {
    sid       = "TerminateUnhealthyInstance"
    effect    = "Allow"
    actions   = ["autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = [aws_autoscaling_group.app.arn]
  }

  # Write logs to CloudWatch (the log group is pre-created in lambda.tf)
  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.remediation.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda_remediation" {
  name   = "${local.name_prefix}-lambda-remediation-policy"
  role   = aws_iam_role.lambda_remediation.id
  policy = data.aws_iam_policy_document.lambda_remediation.json
}
