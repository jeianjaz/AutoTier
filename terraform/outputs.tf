###############################################################################
# outputs.tf
#
# The public API of this Terraform stack. Anything not listed here is
# considered an internal implementation detail that might change without
# breaking downstream code.
#
# Convention: outputs are snake_case, their `description` fields are
# human-readable sentences, and lists are plural ("subnet_ids" not
# "subnet_id"). These are tiny habits that compound in a large codebase.
###############################################################################

# --- VPC ---------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the main VPC. Consumed by every downstream module (SGs, RDS, EC2)."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR of the main VPC. Useful for building security-group rules that allow 'anything in the VPC'."
  value       = aws_vpc.main.cidr_block
}

# --- SUBNETS -----------------------------------------------------------------
#
# We expose the subnet IDs as lists (one per AZ). Downstream resources like
# the ALB or RDS subnet group need multiple subnets, so a list is the
# natural shape.

output "public_subnet_ids" {
  description = "Public-tier subnet IDs across AZs. ALB uses these; NAT lives in the first one."
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "App-tier (private) subnet IDs. The EC2 Auto Scaling Group launches instances here."
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "Data-tier (private, no egress) subnet IDs. RDS subnet group is built from these."
  value       = aws_subnet.data[*].id
}

# --- GATEWAYS ----------------------------------------------------------------

output "internet_gateway_id" {
  description = "ID of the VPC's Internet Gateway."
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_id" {
  description = "ID of the single NAT Gateway in AZ-1a. Only referenced by the app-tier route table today, but exposed for future observability (e.g., a CloudWatch alarm on NAT port-allocation errors)."
  value       = aws_nat_gateway.main.id
}

output "nat_gateway_public_ip" {
  description = "Static public IP the NAT uses as the source for outbound traffic. Useful to whitelist in third-party APIs (e.g., 'AutoTier's app instances appear as this IP to the outside world')."
  value       = aws_eip.nat.public_ip
}

# --- ROUTE TABLES ------------------------------------------------------------
#
# Not strictly required today, but cheap to expose -- future modules (VPC
# endpoints, peering connections) attach routes to these.

output "public_route_table_id" {
  description = "ID of the public route table (0.0.0.0/0 -> IGW)."
  value       = aws_route_table.public.id
}

output "app_route_table_id" {
  description = "ID of the app-tier route table (0.0.0.0/0 -> NAT)."
  value       = aws_route_table.app.id
}

output "data_route_table_id" {
  description = "ID of the data-tier route table (no egress; local VPC traffic only)."
  value       = aws_route_table.data.id
}

# --- SECURITY GROUPS ----------------------------------------------------------
#
# Exposed so downstream resources (ALB, ASG launch template, RDS) can attach
# the right SG without reaching into security_groups.tf internals.

output "alb_security_group_id" {
  description = "SG to attach to the Application Load Balancer."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "SG to attach to EC2 instances launched by the Auto Scaling Group."
  value       = aws_security_group.app.id
}

output "rds_security_group_id" {
  description = "SG to attach to the RDS DB instance."
  value       = aws_security_group.rds.id
}

# --- DATABASE ----------------------------------------------------------------
#
# The EC2 app in Step 4 will consume `db_endpoint` (to connect) and
# `db_secret_arn` (to fetch the password via Secrets Manager + IAM role).

output "db_endpoint" {
  description = "RDS DNS endpoint the app connects to. Resolves to the current primary; automatically updated by AWS during failover."
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "Port MySQL listens on inside the RDS instance."
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Initial schema name created inside the MySQL instance."
  value       = aws_db_instance.main.db_name
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding master username + password. Used by the EC2 IAM policy in Step 4."
  value       = aws_secretsmanager_secret.db_master.arn
}

# db_master_password is intentionally NOT output -- even marked `sensitive`,
# outputs are still readable via `terraform output -raw` and visible in CI
# logs. Passwords ONLY leave the state file via Secrets Manager GetSecretValue.

# --- EC2 APP -----------------------------------------------------------------

output "app_instance_id" {
  description = "Instance ID of the app tier EC2. Use with SSM: `aws ssm start-session --target <this>`."
  value       = aws_instance.app.id
}

output "app_private_ip" {
  description = "Private IP of the app instance. No public IP exists by design."
  value       = aws_instance.app.private_ip
}

output "ssm_session_command" {
  description = "Copy-paste command to open a shell on the app instance via SSM Session Manager. No SSH keys, no port 22."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}"
}

output "app_curl_command" {
  description = "From INSIDE the SSM session, run this to hit the app's health endpoint locally."
  value       = "curl -s http://localhost:8080/health && echo"
}
