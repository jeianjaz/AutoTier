###############################################################################
# vpc.tf
#
# The Virtual Private Cloud — our own isolated network inside AWS.
# Every EC2, RDS, and ALB in this project lives inside this VPC.
#
# WHY these settings?
#   - `enable_dns_support` + `enable_dns_hostnames` are required for RDS
#     endpoints and internal service discovery via DNS names (not IPs).
#     Turn them OFF and you'll spend hours debugging "why can't my EC2
#     reach the RDS endpoint." Always on. No exceptions.
#   - `cidr_block = 10.0.0.0/16` gives us 65,536 addresses — plenty of
#     room. The 10.0.0.0/8 range is RFC 1918 private space (not routable
#     on the internet), same as what every real corporate network uses.
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}
