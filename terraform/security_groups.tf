###############################################################################
# security_groups.tf
#
# Three security groups forming a defense-in-depth chain:
#
#   Internet -> ALB SG (CIDR ingress) -> App SG (SG ref) -> RDS SG (SG ref)
#
# DESIGN PRINCIPLES
# -----------------
# 1. Inside the VPC, ingress is ALWAYS authorized by SG reference, never by
#    CIDR. The only CIDR ingress in this whole file is the ALB accepting
#    HTTP/HTTPS from 0.0.0.0/0 -- because the public internet has no SG.
#
# 2. Each SG is paired with separate rule resources
#    (aws_vpc_security_group_ingress_rule / aws_vpc_security_group_egress_rule)
#    instead of inline blocks. Reason: inline rules force Terraform to revoke
#    + re-create on every diff, which can drop live traffic. Separate rules
#    update atomically and are the post-2023 AWS-recommended pattern.
#
# 3. We do NOT open SSH (22) anywhere. Production access goes through
#    Systems Manager Session Manager (SSM) which uses outbound HTTPS only.
#    No bastion host, no key pairs, no port 22.
###############################################################################


# =============================================================================
# ALB SECURITY GROUP -- the public-facing edge
# =============================================================================
#
# WHY a separate SG for the ALB?
#   The ALB is the ONLY thing in this VPC the internet can reach. Isolating
#   it makes the trust boundary obvious: "anything sourced from this SG
#   already came through the ALB's listener."

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB ingress from internet on 80/443; egress to app tier on 8080."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
    Tier = "public"
  }

  # SGs cannot be replaced if attached to running ENIs.
  # `create_before_destroy` lets Terraform attach the new SG before
  # destroying the old one -- avoids apply errors on rename or VPC migration.
  lifecycle {
    create_before_destroy = true
  }
}

# Inbound HTTP from the internet. Some clients still hit :80 first; the ALB
# listener will redirect to :443 (configured in alb.tf later).
resource "aws_vpc_security_group_ingress_rule" "alb_http_from_internet" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from anywhere (will be redirected to HTTPS)."

  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
  cidr_ipv4   = "0.0.0.0/0"
}

# Inbound HTTPS from the internet -- the actual user traffic.
resource "aws_vpc_security_group_ingress_rule" "alb_https_from_internet" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS from anywhere (real production listener)."

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
  cidr_ipv4   = "0.0.0.0/0"
}

# Outbound: ALB needs to reach app instances on 8080. Tighter than "all" --
# explicit egress documents intent and shrinks the blast radius if the ALB
# is ever compromised.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id = aws_security_group.alb.id
  description       = "Forward to app tier on 8080."

  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.app.id
}


# =============================================================================
# APP SECURITY GROUP -- private compute tier
# =============================================================================
#
# Trust model: app instances accept traffic ONLY from the ALB SG. Anything
# else -- even another app instance trying to reach :8080 directly -- is
# denied. This prevents a compromised app instance from attacking peers.

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app-sg"
  description = "App ingress from ALB on 8080; egress unrestricted (NAT-mediated)."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-app-sg"
    Tier = "app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Inbound 8080 ONLY from ALB SG (not from a CIDR -- this is the key idea).
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id = aws_security_group.app.id
  description       = "Accept traffic on 8080 only from the ALB security group."

  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

# Outbound: allow all. EC2 needs to reach RDS (3306), AWS APIs (443), package
# repos (443/80), CloudWatch endpoints. Enumerating every AWS service IP is
# impractical for a small team. NAT Gateway already constrains the path;
# SGs don't need to repeat that.
resource "aws_vpc_security_group_egress_rule" "app_all_out" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound (mediated by NAT for internet, SG for RDS)."

  ip_protocol = "-1" # -1 = all protocols
  cidr_ipv4   = "0.0.0.0/0"
}


# =============================================================================
# RDS SECURITY GROUP -- the data tier crown jewel
# =============================================================================
#
# Trust model: ONLY the app tier can reach MySQL on 3306. Nothing else.
# Not the ALB, not the NAT, not even another RDS instance.
#
# No egress rule defined. RDS doesn't initiate outbound -- the app always
# opens the connection. With no egress rule defined here, AWS auto-attaches
# a default "allow all" egress, which is harmless because RDS has no
# business calling out anywhere. To enforce zero egress strictly, you'd
# add an egress rule that allows nothing.

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "RDS MySQL ingress from app tier on 3306. No egress configured."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds-sg"
    Tier = "data"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The single rule that protects the database: 3306 from App SG, period.
resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id = aws_security_group.rds.id
  description       = "MySQL ingress on 3306 from app tier only."

  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.app.id
}
