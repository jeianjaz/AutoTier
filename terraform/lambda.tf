###############################################################################
# lambda.tf
#
# Step 7 — auto-remediation Lambda.
#
# This function subscribes to the same SNS topic that emails us (Step 6).
# When the headline alarm (alb-unhealthy-hosts) fires:
#
#   1. Lambda receives the alarm JSON via SNS.
#   2. Queries DescribeTargetHealth to find which instance(s) are unhealthy.
#   3. Calls TerminateInstanceInAutoScalingGroup(ShouldDecrementDesiredCapacity=False).
#   4. The ASG sees desired ≠ actual and launches a replacement.
#   5. New instance passes /health → alarm returns to OK → you get a recovery email.
#
# Total detection-to-replacement: ~90s (60s alarm period + Lambda + boot).
#
# RESOURCES
# ---------
#   1. data "archive_file"          -> zips handler.py for upload
#   2. aws_lambda_function          -> the function itself
#   3. aws_cloudwatch_log_group     -> log retention (14d)
#   4. aws_sns_topic_subscription   -> SNS → Lambda trigger
#   5. aws_lambda_permission        -> lets SNS invoke the function
#
# The IAM role + policy for the Lambda live in iam.tf alongside the EC2 role.
###############################################################################


# =============================================================================
# PACKAGE THE SOURCE CODE
# =============================================================================
#
# `archive_file` creates a zip from the handler.py at plan time. This is the
# simplest packaging for a single-file Lambda with no external dependencies
# (boto3 is included in the Lambda runtime).

data "archive_file" "remediation" {
  type        = "zip"
  source_file = "${path.module}/../lambda/remediation/handler.py"
  output_path = "${path.module}/../lambda/remediation/handler.zip"
}


# =============================================================================
# LOG GROUP -- created BEFORE the function so Lambda doesn't auto-create one
# with infinite retention (and infinite cost).
# =============================================================================

resource "aws_cloudwatch_log_group" "remediation" {
  name              = "/aws/lambda/${local.name_prefix}-remediation"
  retention_in_days = 14

  tags = {
    Name = "${local.name_prefix}-remediation-logs"
  }
}


# =============================================================================
# THE FUNCTION
# =============================================================================

resource "aws_lambda_function" "remediation" {
  function_name = "${local.name_prefix}-remediation"
  description   = "Auto-remediation: terminates unhealthy ALB targets so the ASG replaces them. Subscribed to the alerts SNS topic."

  runtime     = "python3.12"
  handler     = "handler.lambda_handler"
  memory_size = 128
  timeout     = 30

  filename         = data.archive_file.remediation.output_path
  source_code_hash = data.archive_file.remediation.output_base64sha256

  role = aws_iam_role.lambda_remediation.arn

  environment {
    variables = {
      TARGET_GROUP_ARN = aws_lb_target_group.app.arn
    }
  }

  # Ensure the log group exists before the function tries to write to it.
  depends_on = [
    aws_cloudwatch_log_group.remediation,
    aws_iam_role_policy.lambda_remediation,
  ]

  tags = {
    Name = "${local.name_prefix}-remediation"
  }
}


# =============================================================================
# SNS SUBSCRIPTION -- Lambda protocol
# =============================================================================
#
# This is the second subscriber on the same topic (the first is the email
# from sns.tf). Both receive every alarm notification. Fan-out at work.

resource "aws_sns_topic_subscription" "lambda_remediation" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.remediation.arn
}


# =============================================================================
# RESOURCE-BASED POLICY -- let SNS invoke this Lambda
# =============================================================================
#
# Unlike IAM policies (which attach to the caller), Lambda resource-based
# policies attach to the TARGET (the function). This statement says
# "SNS may call lambda:InvokeFunction on THIS function, but only from
# THIS specific topic ARN." Without it, the subscription silently fails.

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}
