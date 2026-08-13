#!/bin/sh
# Tear down the full stack. Run this when you're done working on or
# demoing the project — the EKS control plane (~$73/mo) and NAT Gateway
# (~$32-35/mo) bill continuously until destroyed; there is no "pause".
set -e

cd "$(dirname "$0")/iac"
tofu destroy -auto-approve
