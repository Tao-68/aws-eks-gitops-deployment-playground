# --- EKS cluster IAM role ---

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- EKS cluster ---
# API endpoint access: public + private (the EKS default). Public so kubectl
# works from a laptop without a VPN/bastion; private so node <-> control-plane
# traffic stays inside the VPC instead of round-tripping over the internet.
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = {
    Name = var.cluster_name
  }
}

# --- Node group IAM role ---

resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_nodes_worker" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_cni" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_nodes_ecr" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# --- Node group ---
# Single t3.small node, not a range: cheapest viable option for a demo
# cluster running ArgoCD + one small app. Trade-off: node group updates
# (e.g. AMI bumps) briefly have 0 Ready nodes since there's no second node
# to roll through first — acceptable here, not something you'd do for a
# real workload. Nodes sit in the private subnets only (no public IPs),
# matching the internal-elb tagging already on those subnets.
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  # On-Demand for now: staying conservative while recovering from the
  # instance-type restriction outage (see node_instance_type). t3.small is
  # allowlisted for both Spot and On-Demand on this account, so Spot could be
  # revisited later as a separate cost optimization once things are stable.
  capacity_type  = "ON_DEMAND"
  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes_worker,
    aws_iam_role_policy_attachment.eks_nodes_cni,
    aws_iam_role_policy_attachment.eks_nodes_ecr,
  ]

  tags = {
    Name = "${var.cluster_name}-node"
  }
}
