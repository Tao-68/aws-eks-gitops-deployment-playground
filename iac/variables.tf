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
  default     = "t3.small"
}

# desired = min = max = 1: a single fixed-size node, not an autoscaling range.
# Cheapest option for a demo cluster; trade-off documented in learnings.md.
variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group."
  type        = number
  default     = 1
}
