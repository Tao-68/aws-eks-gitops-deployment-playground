#!/bin/sh
# Spin up the full stack (VPC + EKS + budget). Run this when you're about to
# work on or demo the project; run down.sh when you're done, since the EKS
# control plane and NAT Gateway bill continuously with no "pause" state.
set -e

cd "$(dirname "$0")/iac"
tofu apply -auto-approve

echo
echo "Updating local kubeconfig..."
aws eks update-kubeconfig --name "$(tofu output -raw eks_cluster_name)" --region "$(tofu output -raw aws_region)"
