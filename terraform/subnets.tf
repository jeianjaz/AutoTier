###############################################################################
# subnets.tf
#
# Six subnets organized as three tiers (public, app, data) x two AZs.
# Each tier is its own aws_subnet resource with count = 2 — one per AZ.
#
# WHY split by tier?
#   - Each tier gets its own route table later:
#       public -> route to Internet Gateway (direct internet)
#       app    -> route to NAT Gateway    (outbound internet only)
#       data   -> no internet route at all (fully isolated)
#   - Security groups are cleaner: "allow from app-tier subnets" is one rule.
#
# WHY count instead of for_each?
#   - `count = length(local.public_subnet_cidrs)` scales automatically if
#     we ever add a 3rd AZ — just add a CIDR to the local and it works.
#   - `count.index` (0 or 1) lets us pick the matching AZ and CIDR.
#
# WHY `map_public_ip_on_launch = true` ONLY for public subnets?
#   - Anything launched in a public subnet (e.g., a NAT Gateway or ALB ENI)
#     needs a public IP to reach the internet. Private subnets MUST NOT
#     auto-assign public IPs — that would defeat their purpose.
###############################################################################

# --- PUBLIC TIER (ALB + NAT Gateway live here) ---------------------------------

resource "aws_subnet" "public" {
  count = length(local.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

# --- APP TIER (EC2 Auto Scaling Group lives here) ------------------------------

resource "aws_subnet" "app" {
  count = length(local.app_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # No public IPs here — app tier is private.

  tags = {
    Name = "${local.name_prefix}-app-${var.availability_zones[count.index]}"
    Tier = "app"
  }
}

# --- DATA TIER (RDS primary + standby live here) -------------------------------

resource "aws_subnet" "data" {
  count = length(local.data_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # Data tier is the most isolated — no internet route at all (added in routes.tf).

  tags = {
    Name = "${local.name_prefix}-data-${var.availability_zones[count.index]}"
    Tier = "data"
  }
}
