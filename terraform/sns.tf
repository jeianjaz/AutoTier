###############################################################################
# sns.tf
#
# Step 6 — observability fan-out point.
#
# One SNS topic, many subscribers:
#   - email -> the on-call engineer (us, for now)
#   - Lambda -> Step 7 auto-remediation
#   - (future) Slack webhook / PagerDuty via AWS Chatbot
#
# CloudWatch alarms in cloudwatch.tf publish to this topic on state change.
# A dedicated topic policy lets cloudwatch.amazonaws.com Publish -- without
# it the alarm transitions to ALARM but no email/Lambda is invoked, and the
# failure is silent (you only notice because the alarm icon is red in the
# console). Most painful "why isn't my alarm working" bug in AWS.
###############################################################################


# =============================================================================
# THE TOPIC
# =============================================================================

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  # Display name shows up as the "From" name on email notifications. Keep
  # it short -- many email clients truncate long sender names.
  display_name = "AutoTier Alerts"

  tags = {
    Name = "${local.name_prefix}-alerts"
  }
}


# =============================================================================
# TOPIC POLICY -- let CloudWatch publish here
# =============================================================================
#
# By default an SNS topic only allows the topic owner (the AWS account)
# to publish. CloudWatch alarms run as a separate AWS service principal
# and need an explicit grant. Without this statement, alarms silently
# fail to deliver -- the alarm transitions to ALARM but nothing flows
# downstream.

data "aws_iam_policy_document" "sns_alerts_policy" {
  # The topic owner (our AWS account) already has implicit full control
  # over their own topic, so no explicit "owner" statement is needed.
  # We only need to grant the CloudWatch service principal permission
  # to publish -- without this, alarm transitions silently fail to send.

  statement {
    sid    = "AllowCloudWatchAlarmsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    # Scope the grant to alarms in THIS account only -- prevents a
    # confused-deputy where another account's alarms could publish here.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_alerts_policy.json
}


# Used in the policy above to scope the CloudWatch grant to our account.
data "aws_caller_identity" "current" {}


# =============================================================================
# EMAIL SUBSCRIPTION
# =============================================================================
#
# AWS sends a "Confirm subscription" email to var.alert_email immediately
# after this resource is created. Until you click the link, the
# subscription stays in `PendingConfirmation` and no alarm emails arrive.
# This is by design -- prevents anyone from spam-subscribing your inbox.
#
# Terraform CANNOT auto-confirm: that would require reading the email,
# which Terraform has no way to do. The README documents the manual step.

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
