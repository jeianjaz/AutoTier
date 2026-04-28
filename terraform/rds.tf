###############################################################################
# rds.tf
#
# The data tier: RDS MySQL 8.0, Multi-AZ, encrypted at rest, with its password
# generated at apply time and stored in AWS Secrets Manager so it never
# appears in code, commit history, env vars, or CI logs.
#
# Decision rationale: see docs/decisions/002-rds-mysql-multi-az.md
#
# CREATION ORDER (Terraform figures this out automatically from references):
#   1. aws_db_subnet_group           (which subnets RDS may use)
#   2. aws_db_parameter_group        (MySQL config knobs)
#   3. random_password               (generate strong password locally)
#   4. aws_secretsmanager_secret     (create empty secret container)
#   5. aws_secretsmanager_secret_version (write the password into it)
#   6. aws_db_instance               (create the actual MySQL DB)
###############################################################################


# =============================================================================
# DB SUBNET GROUP
# =============================================================================
#
# A named list of subnets RDS can place the primary + standby in. For
# Multi-AZ this list must cover at least 2 distinct AZs -- otherwise AWS
# has nowhere to put the standby and apply fails.
#
# We use the DATA-tier subnets from the VPC. They have no internet route
# at all, which is exactly what the database needs (see routes.tf).

resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db-subnet-group"
  description = "Data-tier subnets across both AZs for RDS placement."
  subnet_ids  = aws_subnet.data[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}


# =============================================================================
# DB PARAMETER GROUP
# =============================================================================
#
# MySQL configuration knobs. Parameter groups are required; RDS always
# attaches ONE to every instance. If you don't make your own, AWS uses
# `default.mysql8.0` which is read-only -- so we always create our own
# even if we don't change much.
#
# We enable the slow query log. In production this surfaces queries that
# take > long_query_time seconds and is the first place you look when the
# DB slows down. Costs nothing; pure observability win.

resource "aws_db_parameter_group" "main" {
  name        = "${local.name_prefix}-mysql80"
  family      = "mysql8.0"
  description = "AutoTier MySQL 8.0 parameter group with slow query log enabled."

  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "2" # log queries slower than 2 seconds
  }

  tags = {
    Name = "${local.name_prefix}-mysql80"
  }
}


# =============================================================================
# PASSWORD + SECRETS MANAGER
# =============================================================================
#
# The "never hardcode passwords" pattern. Three resources work together:
#
#   1. random_password  -> generate 32-char strong password in memory
#   2. secret           -> create the named Secrets Manager entry
#   3. secret_version   -> store the actual value as JSON inside the secret
#
# The password ends up in the Terraform state file (encrypt your state
# bucket in real life!), but it NEVER appears in any .tf, .tfvars,
# environment variable, or CI log.
#
# At runtime, EC2's IAM role grants secretsmanager:GetSecretValue on this
# secret's ARN, the app calls the API, and the password is delivered over
# TLS. We will wire that up in Step 4 (EC2 user data).

resource "random_password" "db_master" {
  length = 32

  # Special chars RDS MySQL does NOT allow: / @ " and the space char.
  # Everything else is fair game.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${local.name_prefix}-db-master"
  description             = "RDS master credentials for AutoTier's MySQL. Consumed by EC2 at runtime via IAM."
  recovery_window_in_days = 0 # immediate hard-delete on destroy; fine for dev

  tags = {
    Name = "${local.name_prefix}-db-master"
  }
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id

  # Store as JSON so downstream consumers can parse username + password
  # in a single API call. This is the AWS-recommended shape for DB secrets.
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_master.result
  })
}


# =============================================================================
# THE DATABASE ITSELF
# =============================================================================

resource "aws_db_instance" "main" {
  # --- Identity --------------------------------------------------------------
  identifier = "${local.name_prefix}-mysql"
  db_name    = var.db_name

  # --- Engine ----------------------------------------------------------------
  engine               = "mysql"
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.main.name

  # --- Storage ---------------------------------------------------------------
  # gp3 is cheaper + faster than gp2 and is the current RDS default for new
  # workloads. 20 GB is more than enough for a demo; RDS can auto-scale.
  allocated_storage     = 20
  max_allocated_storage = 100 # auto-grow cap
  storage_type          = "gp3"
  storage_encrypted     = true # encryption at rest, AWS-managed KMS key

  # --- Networking ------------------------------------------------------------
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # NEVER true in this project

  # --- HA: THE WHOLE POINT ---------------------------------------------------
  multi_az = true

  # --- Authentication --------------------------------------------------------
  username = var.db_username
  password = random_password.db_master.result

  # --- Backups ---------------------------------------------------------------
  backup_retention_period = 0
  backup_window           = "03:00-04:00" # 03:00-04:00 UTC = 11 AM PHT
  maintenance_window      = "Sun:04:00-Sun:05:00"

  # --- Lifecycle / teardown-friendly defaults --------------------------------
  # DEV DEFAULTS (will flip for "production" framing in Step 11):
  #   - skip_final_snapshot = true   -> `destroy` doesn't take a snapshot
  #   - deletion_protection  = false -> `destroy` is allowed
  # For prod you'd absolutely want both to be the safer values.
  skip_final_snapshot = true
  deletion_protection = false

  # --- Observability ---------------------------------------------------------
  # Send errors + slow query + general logs to CloudWatch Logs so we can
  # alarm on them and grep them centrally. The logs themselves cost
  # ~pennies for this workload.
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  # --- Upgrades --------------------------------------------------------------
  auto_minor_version_upgrade = true

  tags = {
    Name = "${local.name_prefix}-mysql"
    Tier = "data"
  }

  # Terraform infers most dependencies from references, but the secret
  # version is referenced only for its side effect (writing the password
  # out), so state it explicitly.
  depends_on = [aws_secretsmanager_secret_version.db_master]
}
