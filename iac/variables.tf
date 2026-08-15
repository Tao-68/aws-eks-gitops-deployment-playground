variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Used in resource names and the kubernetes.io/cluster/<name> subnet tag that EKS and the AWS Load Balancer Controller use to discover subnets."
  type        = string
  default     = "gitops-portfolio"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

# Only 2 AZs are used (not 3) to keep this portfolio project cheap and simple.
# EKS only requires subnets in at least 2 AZs for control plane HA, so this is
# the minimum viable spread rather than a production-grade 3-AZ layout.
variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 2
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, one per AZ."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "monthly_budget_limit" {
  description = "Monthly cost budget limit (USD) that alert thresholds are measured against."
  type        = string
  default     = "20"
}

variable "budget_alert_email" {
  description = "Email address notified when forecasted spend crosses a budget threshold."
  type        = string
  default     = "tanyuntao99@gmail.com"
}

variable "node_instance_type" {
  description = "EC2 instance type for the EKS managed node group."
  type        = string
  # t3.medium isn't on this account's Free Tier-eligible instance type
  # allowlist (confirmed via repeated launch failures for both Spot and
  # On-Demand) - a new-account guardrail, not something configurable around.
  # Back to t3.small (which is allowlisted); pod-ceiling problem is instead
  # solved by running 2 nodes instead of 1 (see node_desired_size).
  default = "t3.small"
}

# 2 nodes, not 1: t3.small's 11-pod ENI limit was hit before CPU/memory ever
# became the constraint (ArgoCD's 7 pods + baseline system pods already fill
# one node). 2 nodes give ~22 pods of aggregate capacity, and as a bonus,
# node group updates no longer drop to 0 Ready nodes since there's always a
# second one to shift onto.
variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group."
  type        = number
  default     = 2
}
