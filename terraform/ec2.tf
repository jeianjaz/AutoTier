###############################################################################
# ec2.tf
#
# This file used to define a single aws_instance for the app tier (Step 4).
# Step 5 replaces that with a launch template + Auto Scaling Group (asg.tf)
# behind an Application Load Balancer (alb.tf).
#
# What remains here is the AMI data source -- it is now consumed by the
# launch template in asg.tf. We keep it in this file so any future
# instance-related lookups have an obvious home.
###############################################################################


# =============================================================================
# AMI LOOKUP -- the freshest Amazon Linux 2023 x86_64 image
# =============================================================================
#
# Pinning an AMI ID would bit-rot quickly (new images ship monthly with
# security patches). Instead we query AWS for the latest AL2023 AMI owned
# by Amazon ("137112412989" is the AL2023 publisher account).

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
