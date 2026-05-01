###############################################################################
# variables.tf
#
# All inputs to the Terraform root module live here. Every variable has a
# description (shown by `terraform plan`) and a type.
#
# WHY declare variables even when we have defaults?
#   - Self-documenting: `terraform console` and IDE tools surface them.
#   - Overridable: CI or a teammate can pass `-var 'aws_region=us-east-1'`
#     without editing code.
#   - Validated: Terraform checks types at plan time (catches typos early).
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Short project identifier used in resource names and tags."
  type        = string
  default     = "autotier"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. /16 gives us 65,536 IPs — plenty of room to carve out /24 subnets."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZs to deploy into. Two AZs is the minimum for Multi-AZ HA; more would add cost without adding learning value for this project."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

# -----------------------------------------------------------------------------
# Database inputs. These are declared as variables (not hard-coded) so the
# same Terraform can spin up "dev" (db.t3.micro, single-AZ) vs "prod"
# (db.t3.small, multi-AZ) just by changing a tfvars file. Defaults are the
# Multi-AZ dev values from ADR-002.
# -----------------------------------------------------------------------------

variable "db_engine_version" {
  description = "MySQL engine version. AWS auto-applies minor patches within the major line."
  type        = string
  default     = "8.0"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is the smallest that supports Multi-AZ and stays near free-tier."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Initial MySQL database (schema) to create inside the instance."
  type        = string
  default     = "autotier"
}

variable "db_username" {
  description = "Master username for the RDS instance. Password is generated at apply time and stored in Secrets Manager -- never configured here."
  type        = string
  default     = "autotier_admin"
}

# -----------------------------------------------------------------------------
# EC2 / app tier inputs
# -----------------------------------------------------------------------------

variable "ec2_instance_type" {
  description = "Instance class for the app tier. t3.micro is the free-tier-eligible x86_64 class and enough for a Flask demo."
  type        = string
  default     = "t3.micro"
}
