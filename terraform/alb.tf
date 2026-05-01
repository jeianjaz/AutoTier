###############################################################################
# alb.tf
#
# The Application Load Balancer that takes public traffic and forwards it to
# the app fleet on port 8080. Three resources:
#
#   1. aws_lb                 -- the load balancer itself (in public subnets)
#   2. aws_lb_target_group    -- the pool that ASG instances register into
#   3. aws_lb_listener        -- the rule "incoming :80 -> forward to TG"
#
# Why HTTP-only (no HTTPS yet)?
#   HTTPS needs an ACM cert (free) tied to a custom domain (real $/year).
#   AutoTier v1 is a portfolio demo on the ALB's default DNS name.
#   Step 11 may add ACM + Route 53 if/when a domain is registered.
###############################################################################


# =============================================================================
# THE LOAD BALANCER
# =============================================================================
#
# - internet-facing: gets a public DNS name and a public IP per AZ.
# - Lives in PUBLIC subnets (one per AZ); IGW carries traffic in/out.
# - Attached to the ALB security group from sg.tf -- which allows 80/443
#   from 0.0.0.0/0 and egress only to the App SG on 8080.

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false # internet-facing

  subnets         = aws_subnet.public[*].id
  security_groups = [aws_security_group.alb.id]

  # When deletion_protection is true, `terraform destroy` errors. Off in
  # dev for the same reason RDS is off (we destroy daily). Step 11's
  # production framing pass flips this to true.
  enable_deletion_protection = false

  # idle_timeout: how long ALB holds an idle connection before closing.
  # Default is 60s; that's already conservative. We keep the default.
  idle_timeout = 60

  # Drop invalid HTTP headers at the edge -- defense against header smuggling.
  drop_invalid_header_fields = true

  tags = {
    Name = "${local.name_prefix}-alb"
    Tier = "public"
  }
}


# =============================================================================
# TARGET GROUP
# =============================================================================
#
# The pool of instances the ALB forwards to. Instances are NOT registered
# here directly -- the ASG (asg.tf) registers/deregisters them as it
# launches and terminates.

resource "aws_lb_target_group" "app" {
  name        = "${local.name_prefix}-app-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  # How long ALB waits before fully removing a deregistering instance.
  # Default is 300s (5 min). Our app is stateless and our chaos test
  # needs fast recovery measurements, so we cut this aggressively.
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port" # same as target port (8080)
    matcher             = "200"
    interval            = 15 # check every 15s
    timeout             = 5  # mark fail after 5s no response
    healthy_threshold   = 2  # 2 consecutive passes -> healthy
    unhealthy_threshold = 2  # 2 consecutive fails  -> unhealthy
  }

  tags = {
    Name = "${local.name_prefix}-app-tg"
  }

  # Target groups can't be replaced if attached; ASG references this
  # by ARN, so create_before_destroy lets renames go through cleanly.
  lifecycle {
    create_before_destroy = true
  }
}


# =============================================================================
# LISTENER
# =============================================================================
#
# A listener binds a port + protocol on the ALB to a default action.
# Our default action is "forward everything to the app target group."
# A more elaborate setup would have multiple listeners, listener rules
# for path-based routing, redirect-to-HTTPS, etc. We keep it minimal.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = {
    Name = "${local.name_prefix}-alb-listener-http"
  }
}
