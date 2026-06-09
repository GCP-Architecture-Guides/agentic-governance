variable "cloud_run_region" {
  description = "Cloud Run region for Glass UI (optional filter; metrics use service_name only)."
  type        = string
  default     = "us-central1"
}

variable "cloud_run_service_name" {
  description = "Glass UI Cloud Run service name for Model Armor log-based metrics."
  type        = string
  default     = "ai-prism-agent-glass-ui"
}

variable "security_google_chat_space" {
  description = "Google Chat space for Model Armor security alerts (separate from token alerts). Format: spaces/AAAA..."
  type        = string
  default     = "spaces/AAQAe7sP7Y4"
}

variable "security_google_chat_display_name" {
  description = "Display name for the Terraform-managed security Google Chat notification channel."
  type        = string
  default     = null
}

variable "security_notification_channel_ids" {
  description = "Pre-existing security notification channel IDs (use if the Chat channel was created manually in Console)."
  type        = list(string)
  default     = []
}

variable "enable_model_armor_security_alerts" {
  description = "Enable Model Armor prompt-injection surge alert when security notification channels are set."
  type        = bool
  default     = true
}

variable "prompt_injection_alert_threshold" {
  description = "Prompt injection matches per window before alerting (default 10 per minute)."
  type        = number
  default     = 10
}

variable "prompt_injection_alert_window_seconds" {
  description = "Rolling window for counting prompt injection matches."
  type        = number
  default     = 60
}

variable "prompt_injection_alert_duration_seconds" {
  description = "How long the breach must persist before firing (0 = immediate)."
  type        = number
  default     = 0
}

variable "demo_project_placeholder" {
  description = "Project id string baked into upstream authorization-debugging.json SQL."
  type        = string
  default     = "duncanjames-agw-tf"
}

variable "notification_channel_ids" {
  description = "Additional pre-existing Cloud Monitoring notification channel IDs (email, PagerDuty, etc.)."
  type        = list(string)
  default     = []
}

variable "slack_channel_name" {
  description = "Slack channel for Agent Observability alerts (e.g. #agentic-lens-alerts)."
  type        = string
  default     = ""
}

variable "slack_auth_token" {
  description = "Slack Bot User OAuth Token (xoxb-...) with chat:write scopes."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_display_name" {
  description = "Display name for the Terraform-managed Slack notification channel."
  type        = string
  default     = null
}

variable "google_chat_space" {
  description = "Google Chat space ID (spaces/AAAA...). Install the Cloud Monitoring app in the space first."
  type        = string
  default     = "spaces/AAQAe7sP7Y4"
}

variable "google_chat_display_name" {
  description = "Display name for the Terraform-managed Google Chat notification channel."
  type        = string
  default     = null
}

variable "enable_token_alerts" {
  description = "Enable Agent Observability alert policies (AL1–AL6) when notification channels are configured."
  type        = bool
  default     = true
}

variable "alert_email_address" {
  description = "AL7: email address for token alert notifications."
  type        = string
  default     = ""
}

variable "alert_email_display_name" {
  description = "Display name for the Terraform-managed email notification channel."
  type        = string
  default     = null
}

variable "enable_alert_baseline_spike" {
  description = "AL1: per-agent spike vs 1-day baseline."
  type        = bool
  default     = true
}

variable "enable_alert_runaway_loop" {
  description = "AL2: suspected runaway LLM loop."
  type        = bool
  default     = true
}

variable "enable_alert_project_surge" {
  description = "AL3: project-wide Vertex token surge."
  type        = bool
  default     = true
}

variable "enable_alert_absolute_ceiling" {
  description = "AL4: per-agent absolute token ceiling."
  type        = bool
  default     = true
}

variable "enable_alert_error_correlation" {
  description = "AL5: per-agent token spike with llm_usage errors."
  type        = bool
  default     = true
}

variable "enable_alert_zero_traffic" {
  description = "AL6: no llm_usage traffic project-wide (optional)."
  type        = bool
  default     = false
}

variable "project_token_surge_threshold" {
  description = "AL3: project tokens per 15-minute bucket before alerting."
  type        = number
  default     = 750000
}

variable "project_surge_duration_seconds" {
  description = "AL3: how long the surge must persist before firing."
  type        = number
  default     = 900
}

variable "per_agent_baseline_spike_percent" {
  description = "AL1: percent increase vs same bucket 1 day ago (200 = 2×)."
  type        = number
  default     = 200
}

variable "per_agent_baseline_spike_duration_seconds" {
  description = "AL1: sustained duration before firing."
  type        = number
  default     = 1800
}

variable "per_agent_absolute_ceiling_threshold" {
  description = "AL4: hard token ceiling per agent per 15-minute bucket."
  type        = number
  default     = 100000
}

variable "per_agent_absolute_ceiling_duration_seconds" {
  description = "AL4: sustained duration before firing."
  type        = number
  default     = 1800
}

variable "runaway_loop_call_threshold" {
  description = "AL2: LLM calls per agent per 15-minute bucket."
  type        = number
  default     = 30
}

variable "runaway_loop_min_tokens" {
  description = "AL2: minimum tokens in the same bucket."
  type        = number
  default     = 5000
}

variable "runaway_loop_duration_seconds" {
  description = "AL2: sustained duration before firing."
  type        = number
  default     = 900
}

variable "error_correlation_token_threshold" {
  description = "AL5: tokens per 15-minute bucket when paired with errors."
  type        = number
  default     = 50000
}

variable "error_correlation_error_threshold" {
  description = "AL5: llm_usage errors per 15-minute bucket per agent."
  type        = number
  default     = 3
}

variable "error_correlation_duration_seconds" {
  description = "AL5: sustained duration before firing."
  type        = number
  default     = 900
}

variable "zero_traffic_duration_seconds" {
  description = "AL6: duration with zero llm_usage calls before alerting."
  type        = number
  default     = 21600
}

variable "per_agent_token_spike_threshold" {
  description = "Deprecated alias for per_agent_absolute_ceiling_threshold (AL4)."
  type        = number
  default     = null
}

variable "per_agent_spike_duration_seconds" {
  description = "Deprecated alias for per_agent_absolute_ceiling_duration_seconds (AL4)."
  type        = number
  default     = null
}

variable "enable_org_observability" {
  description = "Create metrics scope members and the Org Agentic Observability dashboard on the hub project."
  type        = bool
  default     = true
}

variable "org_metrics_scope_project_id" {
  description = "Hub GCP project for org metrics scope and org dashboard. Defaults to project_id when null."
  type        = string
  default     = null
}

variable "org_monitored_project_ids" {
  description = "Additional GCP projects to add to the hub metrics scope (hub project is always included)."
  type        = list(string)
  default     = []
}

variable "domain" {
  description = "The custom domain pointing to the Load Balancer IP."
  type        = string
  default     = ""
}

variable "iap_client_id" {
  description = "OAuth 2.0 Client ID for IAP."
  type        = string
  default     = ""
}

variable "iap_client_secret" {
  description = "OAuth 2.0 Client Secret for IAP."
  type        = string
  default     = ""
  sensitive   = true
}
