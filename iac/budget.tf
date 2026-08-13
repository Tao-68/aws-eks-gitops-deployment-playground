# Account-level cost budget, independent of any resource in this VPC — it
# doesn't depend on EKS/EC2 existing, so it's set up now, before the resources
# that actually cost money (NAT Gateway, later the EKS control plane) accrue
# spend. FORECASTED thresholds (not ACTUAL) alert on projected month-end spend
# based on the current trend, catching a runaway cost before it fully happens
# rather than after.
resource "aws_budgets_budget" "monthly_cost" {
  name         = "${var.cluster_name}-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
