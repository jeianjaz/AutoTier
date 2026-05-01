###############################################################################
# cloudwatch.tf
#
# Step 6 -- five CloudWatch metric alarms covering the three tiers:
#
#   ALB tier:  alb-unhealthy-hosts        <- the headline alarm; starts the
#                                            MTTR clock for the Step 8 chaos test
#   App tier:  asg-cpu-high               <- pre-scaling signal
#   Data tier: rds-cpu-high               <- runaway query / connection storm
#              rds-connections-high       <- t3.micro caps near 66 conns
#              rds-storage-low            <- disk-full = read-only RDS
#
# Every alarm publishes to the same SNS topic (sns.tf), which fans out to:
#   - the on-call email (us)
#   - the Step 7 auto-remediation Lambda (added next step)
#
# Why `treat_missing_data = "notBreaching"` everywhere?
#   When Terraform first creates these alarms, the underlying metric may not
#   have a single datapoint yet (e.g. the ASG instances are still booting,
#   so CPU is "missing", not "high"). Without this setting, CloudWatch would
#   treat "missing" as "breaching" and immediately fire the alarm. We want
#   missing data to be silent until real data arrives.
###############################################################################


# =============================================================================
# ALB TIER -- the headline alarm
# =============================================================================
#
# UnHealthyHostCount is the metric ALB exposes for "how many of my registered
# targets are failing the /health check right now". When the Step 8 chaos
# script kills an instance, this metric will go from 0 -> 1 within ~15s
# (one health-check interval), and the alarm transitions to ALARM within
# another ~60s (one evaluation period). Total detection time: ~75s.
#
# Dimensions matter: this metric is keyed by BOTH the load balancer AND
# the target group, so we must supply both. `arn_suffix` (not `arn`) is
# the correct attribute for CloudWatch dimensions -- it's the bit after
# `loadbalancer/` in the ARN, e.g. `app/autotier-dev-alb/abc123...`.

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name        = "${local.name_prefix}-alb-unhealthy-hosts"
  alarm_description = "One or more ALB targets failing /health. Step 7 Lambda will auto-remediate; Step 8 chaos test measures MTTR off this transition."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  statistic   = "Maximum"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  # 60-second period, fire on 1 of 1 datapoint -- minimum latency.
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1

  treat_missing_data = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${local.name_prefix}-alb-unhealthy-hosts"
    Tier = "alb"
  }
}


# =============================================================================
# APP TIER -- ASG CPU
# =============================================================================
#
# CPUUtilization on AWS/EC2 with the AutoScalingGroupName dimension gives us
# the AVERAGE CPU across all instances in the ASG. That's the right signal
# for scaling decisions; a single hot instance dragging up the average is
# itself a problem worth knowing about.
#
# 80% / 2 minutes is a deliberately gentle threshold for now -- Step 11 will
# attach a step-scaling policy here.

resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name        = "${local.name_prefix}-asg-cpu-high"
  alarm_description = "Average ASG CPU >= 80% for 2 minutes. Pre-scaling signal; Step 11 will attach a scale-out policy."

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 80

  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  treat_missing_data = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${local.name_prefix}-asg-cpu-high"
    Tier = "app"
  }
}


# =============================================================================
# DATA TIER -- RDS CPU
# =============================================================================
#
# 5-minute window is intentional: a brief CPU spike from a heavy backup or
# vacuum is not actionable. Sustained high CPU usually means a missing
# index, a runaway query, or a connection storm.

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name        = "${local.name_prefix}-rds-cpu-high"
  alarm_description = "RDS CPU >= 80% for 5 minutes. Investigate slow queries or connection storms."

  namespace   = "AWS/RDS"
  metric_name = "CPUUtilization"
  statistic   = "Average"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 80

  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  treat_missing_data = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${local.name_prefix}-rds-cpu-high"
    Tier = "data"
  }
}


# =============================================================================
# DATA TIER -- RDS connection count
# =============================================================================
#
# t3.micro RDS has max_connections derived from instance memory (~66 for MySQL
# on a 1 GB box). Threshold of 40 gives us a 2/3 buffer before the database
# starts refusing connections -- which manifests in the app as 500s.

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name        = "${local.name_prefix}-rds-connections-high"
  alarm_description = "RDS DatabaseConnections >= 40 for 5 minutes. t3.micro caps near 66; this signals a connection leak before the app starts 500ing."

  namespace   = "AWS/RDS"
  metric_name = "DatabaseConnections"
  statistic   = "Average"

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 40

  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  treat_missing_data = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${local.name_prefix}-rds-connections-high"
    Tier = "data"
  }
}


# =============================================================================
# DATA TIER -- RDS free storage
# =============================================================================
#
# FreeStorageSpace is reported in BYTES. 2 GB = 2 * 1024^3 = 2147483648.
# Why 2 GB on a 20 GB volume? RDS goes read-only when free space hits ~0,
# and storage autoscaling (which we don't enable on free-tier) reacts at
# 10% remaining. 2 GB gives a real human enough warning to act manually.

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name        = "${local.name_prefix}-rds-storage-low"
  alarm_description = "RDS FreeStorageSpace <= 2 GB for 5 minutes. RDS goes read-only at ~0 bytes free; act NOW (resize, prune, or enable storage autoscaling)."

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"
  statistic   = "Average"

  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = 2 * 1024 * 1024 * 1024 # 2 GiB in bytes

  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5

  treat_missing_data = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "${local.name_prefix}-rds-storage-low"
    Tier = "data"
  }
}
