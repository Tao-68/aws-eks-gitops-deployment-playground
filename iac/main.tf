terraform {
  # >= 1.12.0 rather than a Terraform-style pin: this project uses OpenTofu,
  # the MPL-licensed fork, so the binary running this must be `tofu`, not `terraform`.
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data source instead of a hardcoded AZ list: AZ names/availability differ per
# account and region (and AWS occasionally retires or adds them), so resolving
# at apply time avoids a plan that silently breaks if run from a different
# account or if eu-central-1's AZ set changes.
data "aws_availability_zones" "available" {
  state = "available"
}

# --- VPC ---

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for EKS: nodes and the control plane rely on DNS resolution within the VPC

  tags = {
    Name = var.cluster_name
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# --- Subnets ---
# slice() caps the AZ list at var.az_count (2) so this scales to more AZs
# just by bumping the variable and adding matching CIDRs, without editing
# resource blocks.

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true # nodes/ELBs in this subnet get a public IP automatically, needed for public-facing load balancers

  tags = {
    Name = "${var.cluster_name}-public-${data.aws_availability_zones.available.names[count.index]}"
    # EKS-required tags: the AWS Load Balancer Controller and the EKS control
    # plane discover subnets by these tags rather than by naming convention.
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.cluster_name}-private-${data.aws_availability_zones.available.names[count.index]}"
    # internal-elb role tags this subnet tier for internal (non-public) load
    # balancers; worker nodes live here so they aren't directly internet-reachable.
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --- NAT Gateway ---
# A single NAT Gateway (not one per AZ) is a deliberate cost tradeoff for a
# personal/portfolio project: each NAT Gateway costs ~$32/mo + data processing,
# so 3 of them would roughly triple that cost for HA that a demo project
# doesn't need. The tradeoff is that all private-subnet egress funnels through
# one AZ, which is a single point of failure — acceptable here, but called out
# because a production setup would use one NAT Gateway per AZ instead.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # placed in the first public subnet; private subnets in both AZs route through it

  tags = {
    Name = "${var.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# --- Route tables ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Single route table shared by both private subnets (not one per AZ): since
# there's only one NAT Gateway anyway, per-AZ route tables would just be
# identical copies pointing at the same NAT — no isolation benefit, just
# extra resources to manage.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
