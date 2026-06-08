resource "google_logging_project_bucket_config" "default_analytics" {
  project          = var.project_id
  location         = "global"
  bucket_id        = "_Default"
  enable_analytics = true
}

locals {
  dashboard_json_raw = replace(
    file("${path.module}/agent-gateway-observability.json"),
    var.demo_project_placeholder,
    var.project_id,
  )
  dashboard_json = replace(
    local.dashboard_json_raw,
    "agentic-ai-lens-placeholder",
    var.project_id,
  )
}

resource "google_monitoring_dashboard" "agent_gateway_observability" {
  project        = var.project_id
  dashboard_json = local.dashboard_json

  depends_on = [google_logging_project_bucket_config.default_analytics]
}
