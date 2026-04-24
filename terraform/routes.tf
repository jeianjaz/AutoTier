###############################################################################
# routes.tf
#
# Three route tables (public / app / data) and six associations that attach
# each subnet to the right table.
#
# A ROUTE TABLE is a list of rules: "traffic for CIDR X goes to target Y".
# Every subnet must be associated with exactly one route table. If you
# don't associate a subnet, AWS attaches it to the VPC's invisible
# "main" route table by default -- which has surprising behavior, so we
# ALWAYS create our own and associate explicitly.
#
# Every route table AUTOMATICALLY has a "local" route (10.0.0.0/16 -> local).
# That's what lets subnets in the same VPC talk to each other without us
# writing a rule. You can't remove it.
###############################################################################

# =============================================================================
# PUBLIC ROUTE TABLE -- 0.0.0.0/0 -> IGW (two-way internet)
# =============================================================================
#
# Attached to: public-1a, public-1b
# Effect: ALB and NAT Gateway (which live here) can both reach the internet
#         and be reached from it.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
    Tier = "public"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =============================================================================
# APP ROUTE TABLE -- 0.0.0.0/0 -> NAT Gateway (outbound-only internet)
# =============================================================================
#
# Attached to: app-1a, app-1b
# Effect: EC2s in private app subnets can `yum update`, pull Docker images,
#         call external APIs -- but NOTHING on the internet can open a
#         connection INTO these EC2s. That's what makes this tier "private."
#
# WHY a separate route table for app?
#   We WANT different behavior per tier. Putting app and data on the same
#   table would either give data internet access (bad) or break app's
#   outbound (bad). One table per tier = one place to reason about each
#   tier's blast radius.

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-app-rt"
    Tier = "app"
  }
}

resource "aws_route_table_association" "app" {
  count = length(aws_subnet.app)

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

# =============================================================================
# DATA ROUTE TABLE -- NO internet route (maximum isolation)
# =============================================================================
#
# Attached to: data-1a, data-1b
# Effect: RDS instances can talk to EC2s in the same VPC (via the automatic
#         local route), but CANNOT reach the internet at all -- not even
#         outbound. If RDS somehow needed to fetch a package it couldn't.
#         That's the point: a compromised database cannot exfiltrate data.
#
# We declare the route table with only tags (no explicit `route` block) so
# it only contains the automatic local route. This is intentional and
# should be a deliberate choice you can defend in an interview:
#   "Data tier has no egress route. Backups go through managed RDS features;
#    nothing in this subnet should ever originate an internet connection."

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-data-rt"
    Tier = "data"
  }
}

resource "aws_route_table_association" "data" {
  count = length(aws_subnet.data)

  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}
