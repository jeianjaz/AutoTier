###############################################################################
# ec2.tf
#
# A single EC2 instance running the AutoTier Flask app. This is intentionally
# NOT yet wrapped in an Auto Scaling Group -- Step 5 refactors it into a
# launch template + ASG behind an ALB. Keeping it a plain instance for now
# makes it easy to SSM in and debug the app before the ASG lifecycle
# complicates things.
#
# DESIGN
# ------
# - Placed in app-tier subnet AZ-1a (arbitrary; Step 5 spreads across AZs).
# - No public IP (app tier is private; internet path is NAT only).
# - No key pair (SSM Session Manager is the access path).
# - IMDSv2 required (HttpTokens = "required") -- blocks SSRF-style attacks
#   that trick the instance into revealing its IAM creds via v1 metadata.
# - EBS root volume encrypted (free with gp3).
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


# =============================================================================
# THE INSTANCE
# =============================================================================

resource "aws_instance" "app" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.ec2_instance_type

  # Placement: first app-tier subnet. Step 5 will remove this instance and
  # have the ASG spread across BOTH app subnets.
  subnet_id              = aws_subnet.app[0].id
  vpc_security_group_ids = [aws_security_group.app.id]

  # IAM binding: the instance profile we built in iam.tf. This grants
  # SecretsManager:GetSecretValue on the DB secret + SSM agent perms.
  iam_instance_profile = aws_iam_instance_profile.app.name

  # IMDSv2 only. Deny legacy v1 calls -- mitigates a wide class of SSRF
  # attacks that leak IAM credentials. Also set the hop limit to 2 so
  # Docker-style networking on the host can still reach it (default is 1).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Encrypted root volume -- the $0 tier of data protection. Always on.
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    tags = {
      Name = "${local.name_prefix}-app-root"
    }
  }

  # user_data_replace_on_change = true means: if the template changes,
  # Terraform will DESTROY + RECREATE the instance on next apply. Safer
  # than trying to re-run user-data on a live host (which cloud-init
  # won't do anyway -- user-data only runs on first boot).
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    db_host       = aws_db_instance.main.address
    db_name       = aws_db_instance.main.db_name
    db_secret_arn = aws_secretsmanager_secret.db_master.arn
    aws_region    = var.aws_region
  })

  tags = {
    Name = "${local.name_prefix}-app"
    Tier = "app"
  }

  # Explicit dependency on the secret VERSION so the instance doesn't try
  # to fetch the password before it's been written. Terraform would
  # eventually figure this out via the templatefile reference to the ARN,
  # but being explicit costs nothing.
  depends_on = [
    aws_secretsmanager_secret_version.db_master,
    aws_db_instance.main,
  ]
}
