###############################################################################
# internet.tf
#
# Three resources that together enable internet connectivity for the VPC:
#
#   1. aws_internet_gateway  -> two-way door for public subnets
#   2. aws_eip               -> static public IP reserved for the NAT
#   3. aws_nat_gateway       -> one-way outbound for private subnets
#
# These are plumbing. The route tables in routes.tf are what actually
# *direct* traffic through them -- a resource on its own does nothing until
# a route points at it.
###############################################################################

# --- INTERNET GATEWAY ---------------------------------------------------------
#
# An IGW is a logical, horizontally-scaled, highly-available VPC component.
# You do not manage its capacity; AWS does. It attaches to exactly one VPC.
#
# By itself the IGW does NOTHING. Only when a route table entry points
# 0.0.0.0/0 at this IGW do packets actually flow.

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# --- ELASTIC IP FOR NAT -------------------------------------------------------
#
# A static, public IPv4 address allocated from Amazon's pool and reserved
# to your account until you release it.
#
# WHY `domain = "vpc"`?
#   Legacy EC2-Classic EIPs existed in a different pool. Every modern
#   VPC EIP must be `domain = "vpc"`. Boilerplate you always set.
#
# WHY `depends_on` the IGW?
#   An EIP attached to a NAT only works if the VPC has a working IGW
#   (the NAT forwards to IGW internally). Making the dependency explicit
#   guarantees Terraform creates the IGW first on apply and destroys it
#   last on destroy, avoiding dependency errors from AWS.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

# --- NAT GATEWAY --------------------------------------------------------------
#
# Lives in a PUBLIC subnet (required -- the NAT itself needs internet access).
# Private subnets route their 0.0.0.0/0 traffic here; the NAT rewrites the
# source IP to its own public IP (the EIP above) and forwards outbound.
#
# WHY only ONE NAT (in public-1a)?
#   Cost: ~$32/month per NAT Gateway + data transfer. A true prod design
#   deploys one NAT per AZ so an AZ failure doesn't also kill outbound
#   internet for the surviving AZ. We accept the trade-off for this project
#   and document it in ADR-001. Real-world interview answer:
#   "I'd switch to one NAT per AZ as soon as uptime budget exceeded the
#    ~$32/month cost."
#
# WHY `connectivity_type = "public"`?
#   There's also "private" NAT for inter-VPC traffic that shouldn't touch
#   the internet. Not relevant here.

resource "aws_nat_gateway" "main" {
  allocation_id     = aws_eip.nat.id
  subnet_id         = aws_subnet.public[0].id # AZ-1a public subnet
  connectivity_type = "public"

  tags = {
    Name = "${local.name_prefix}-nat"
  }

  # NAT Gateway creation requires the IGW to already exist in the VPC,
  # otherwise AWS returns a dependency error.
  depends_on = [aws_internet_gateway.main]
}
