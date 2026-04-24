###############################################################################
# locals.tf
#
# "Locals" are computed values derived from variables. Think of them as
# private variables — they can't be overridden from the CLI like `var.*`.
#
# WHY use locals here?
#   - Subnet CIDRs follow a pattern: public=10.0.{1,2}.0/24, app=10.0.{11,12}.0/24,
#     data=10.0.{21,22}.0/24. Encoding the pattern ONCE here means the code stays
#     consistent even if we later change the scheme.
#   - `name_prefix` keeps every resource's Name tag consistent
#     (e.g. "autotier-dev-vpc", "autotier-dev-public-1a").
###############################################################################

locals {
  # e.g. "autotier-dev" — used as a prefix for Name tags
  name_prefix = "${var.project_name}-${var.environment}"

  # Two-tier subnet plan. Keeping tiers in their own /24 means we can
  # grow each tier independently and security groups stay readable.
  #
  #   10.0.1.0/24   public-1a   (ALB, NAT)
  #   10.0.2.0/24   public-1b   (ALB second subnet attachment)
  #   10.0.11.0/24  app-1a      (EC2 auto scaling group)
  #   10.0.12.0/24  app-1b      (EC2 auto scaling group)
  #   10.0.21.0/24  data-1a     (RDS primary)
  #   10.0.22.0/24  data-1b     (RDS standby)
  public_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24"]
  app_subnet_cidrs    = ["10.0.11.0/24", "10.0.12.0/24"]
  data_subnet_cidrs   = ["10.0.21.0/24", "10.0.22.0/24"]
}
