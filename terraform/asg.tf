###############################################################################
# asg.tf
#
# Replaces the single aws_instance from Step 4 with a launch template +
# Auto Scaling Group. Same Flask app, same IAM, same SG, now redundant
# across both app subnets and self-healing on app-level failure.
#
# Decision rationale: see docs/decisions/003-asg-over-auto-recovery.md
#
# WHAT GETS REUSED FROM STEP 4
# ----------------------------
#   - data.aws_ami.al2023        (ec2.tf -- AMI lookup)
#   - aws_iam_instance_profile.app (iam.tf)
#   - aws_security_group.app     (security_groups.tf)
#   - user_data.sh.tftpl         (cloud-init template)
#   - aws_db_instance.main / secret (passed via templatefile vars)
#
# That clean reuse is the payoff for keeping Step 4 well-factored.
###############################################################################


# =============================================================================
# LAUNCH TEMPLATE -- "how to make one instance"
# =============================================================================
#
# A launch template is versioned: every change creates a new version.
# `update_default_version = true` makes Terraform also bump the default
# version pointer, so the ASG (which references "$Latest") picks up the
# change on next instance replacement.

resource "aws_launch_template" "app" {
  name_prefix            = "${local.name_prefix}-app-"
  description            = "AutoTier app: AL2023 + Flask via cloud-init, IAM-scoped, IMDSv2-only."
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.app.name
  }

  # Network: SG only here -- the ASG decides which subnet each instance
  # lands in (it spreads across the subnets we hand it).
  vpc_security_group_ids = [aws_security_group.app.id]

  # IMDSv2 ONLY. Same reasoning as ec2.tf: blocks SSRF cred theft.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Encrypted gp3 root volume -- the $0 data-protection tier.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }

  # user_data must be base64-encoded for launch templates (unlike
  # aws_instance which auto-encodes). templatefile() returns a string;
  # base64encode wraps it.
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    db_host       = aws_db_instance.main.address
    db_name       = aws_db_instance.main.db_name
    db_secret_arn = aws_secretsmanager_secret.db_master.arn
    aws_region    = var.aws_region
  }))

  # Tags applied to instances launched from this template. ASG-level
  # tags propagate too; this is for tags that should appear on EVERY
  # ENI/volume regardless of how the ASG tags them.
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name_prefix}-app"
      Tier = "app"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name_prefix}-app-root"
    }
  }

  tags = {
    Name = "${local.name_prefix}-app-lt"
  }

  lifecycle {
    create_before_destroy = true
  }
}


# =============================================================================
# AUTO SCALING GROUP -- "manage a fleet of these"
# =============================================================================

resource "aws_autoscaling_group" "app" {
  name                = "${local.name_prefix}-app-asg"
  vpc_zone_identifier = aws_subnet.app[*].id

  min_size         = var.asg_min_size
  desired_capacity = var.asg_desired_capacity
  max_size         = var.asg_max_size

  # Register every instance with the ALB target group. The ASG handles
  # registration/deregistration on launch and terminate.
  target_group_arns = [aws_lb_target_group.app.arn]

  # CRITICAL: "ELB" not "EC2".
  # "EC2"  -> ASG only kills instances that fail EC2 hardware checks.
  # "ELB"  -> ASG also kills instances that fail the ALB target group's
  #           health check (i.e., your app died, OOM'd, hung, etc.).
  # The chaos test depends on this -- "EC2" mode would make killing the
  # Flask process invisible to the ASG.
  health_check_type         = "ELB"
  health_check_grace_period = 180 # cloud-init takes ~90s; give buffer

  # Wait at apply time until each new instance reaches healthy. Prevents
  # `terraform apply` from saying "done" while instances are still booting.
  wait_for_capacity_timeout = "10m"
  min_elb_capacity          = var.asg_min_size

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  # ASG-level tag propagation. propagate_at_launch = true means the tag
  # is applied to each instance the ASG launches. Important for cost
  # allocation and the chaos test's instance discovery (filter by Tier=app).
  dynamic "tag" {
    for_each = {
      Name        = "${local.name_prefix}-app"
      Tier        = "app"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # Default termination policy + instance protection off. We WANT the
  # ASG free to terminate any instance during chaos tests / scale-in.
  termination_policies = ["OldestInstance"]

  lifecycle {
    # If we tweak the launch template, force a rolling replacement
    # rather than just bumping the version (which only affects new
    # launches). This makes user-data changes propagate immediately.
    create_before_destroy = true
  }
}
