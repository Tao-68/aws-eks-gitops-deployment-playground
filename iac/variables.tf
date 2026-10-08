variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-central-1"
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

variable "github_repo" {
  description = "GitHub repo (owner/name) allowed to assume the CI IAM role via OIDC."
  type        = string
  default     = "Tao-68/aws-eks-gitops-deployment-playground"
}
