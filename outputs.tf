output "project_id" {
  description = "GCP project where observability resources were created."
  value       = var.project_id
}

output "agent_gateway_observability_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Agent Gateway Observability."
  value       = module.gateway_observability.dashboard_id
}

output "agent_observability_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Agent Observability (token usage)."
  value       = module.agent_observability.dashboard_id
}

output "agent_observability_llm_log_metrics" {
  description = "Log-based metric names for per-agent LLM usage."
  value       = module.agent_observability.llm_log_metric_names
}

output "agent_observability_alert_policy_ids" {
  description = "Token alert policy IDs (null when notification channels are not set)."
  value       = module.agent_observability.alert_policy_ids
}

output "agent_observability_notification_channels" {
  description = "Notification channels wired to Agent Observability alerts."
  value = {
    all         = module.agent_observability.notification_channel_ids
    slack       = module.agent_observability.managed_notification_channels.slack
    google_chat = module.agent_observability.managed_notification_channels.google_chat
    email       = module.agent_observability.managed_notification_channels.email
  }
}

output "log_bucket_config_id" {
  description = "Log bucket config id (_Default with Log Analytics enabled)."
  value       = module.gateway_observability.log_bucket_id
}

output "model_armor_log_metric_ids" {
  description = "User-defined log-based metric resource ids for Model Armor."
  value       = module.lens_model_armor.metric_ids
}

output "model_armor_security_alert_policy_ids" {
  description = "Model Armor security alert policy IDs."
  value       = module.lens_model_armor.security_alert_policy_ids
}

output "model_armor_security_notification_channels" {
  description = "Notification channels wired to Model Armor security alerts."
  value = {
    all         = module.lens_model_armor.security_notification_channel_ids
    google_chat = module.lens_model_armor.managed_security_notification_channels.google_chat
  }
}

output "gateway_log_metric_ids" {
  description = "User-defined log-based metric names for Agent Gateway egress."
  value       = module.gateway_observability.gateway_log_metric_ids
}

output "org_agentic_observability_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Org Agentic Observability (null when disabled)."
  value       = length(module.org_observability) > 0 ? module.org_observability[0].dashboard_id : null
}

output "org_metrics_scope" {
  description = "Hub project and additional projects in the org metrics scope."
  value = length(module.org_observability) > 0 ? {
    hub_project_id        = module.org_observability[0].metrics_scope_project_id
    monitored_project_ids = module.org_observability[0].monitored_project_ids
    all_project_ids       = module.org_observability[0].all_project_ids
    dashboard_console_url = module.org_observability[0].dashboard_console_url
  } : null
}
