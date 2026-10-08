output "aws_region" {
  description = "AWS region resources are deployed in."
  value       = var.aws_region
}

/*
output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per AZ. Needed for public-facing load balancers and the EKS cluster's public subnet config."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per AZ. Needed for EKS worker nodes and internal load balancers."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "AZ names used, in the same order as the subnet ID lists."
  value       = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

output "nat_gateway_public_ip" {
  description = "Public (Elastic) IP of the single NAT Gateway. Useful for allowlisting egress traffic from private subnets on external services."
  value       = aws_eip.nat.public_ip
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster. Pass to `aws eks update-kubeconfig --name <this>`."
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint for the EKS cluster."
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_certificate_authority" {
  description = "Base64-encoded cluster CA certificate, needed to build a kubeconfig manually."
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "eks_node_group_name" {
  description = "Name of the EKS managed node group."
  value       = aws_eks_node_group.main.node_group_name
}

output "ecr_repository_url" {
  description = "URL of the ECR repository for the sample app image."
  value       = aws_ecr_repository.app.repository_url
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC. Set this as the AWS_ROLE_ARN repository variable (Settings > Secrets and variables > Actions > Variables)."
  value       = aws_iam_role.github_actions.arn
}
*/