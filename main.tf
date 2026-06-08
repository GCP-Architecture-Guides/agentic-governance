provider "google" {
  project = var.project_id
  region  = var.location
}

provider "google-beta" {
  project = var.project_id
  region  = var.location
}

variable "prefix" {
  type    = string
  default = "gemini-corp"
}

variable "project_id" {
  type    = string
  default = "agentic-security-dev"
}

variable "location" {
  type    = string
  default = "us-central1"
}

# Services
resource "google_project_service" "compute" {
  service = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "modelarmor" {
  service = "modelarmor.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networksecurity" {
  service = "networksecurity.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networkservices" {
  service = "networkservices.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "aiplatform" {
  service = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "discoveryengine" {
  service = "discoveryengine.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "apphub" {
  service = "apphub.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  service = "iam.googleapis.com"
  disable_on_destroy = false
}

# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

# Proxy-only subnet for SWP
resource "google_compute_subnetwork" "proxy_subnet" {
  name          = "${var.prefix}-proxy-subnet"
  ip_cidr_range = "100.100.10.0/26"
  region        = var.location
  network       = google_compute_network.vpc.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# SWP Subnet
resource "google_compute_subnetwork" "swp_subnet" {
  name          = "${var.prefix}-swp-subnet"
  ip_cidr_range = "10.10.10.0/28"
  region        = var.location
  network       = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Interface Subnet for Network Attachment
resource "google_compute_subnetwork" "intf_subnet" {
  name          = "${var.prefix}-intf-subnet"
  ip_cidr_range = "192.168.10.0/28"
  region        = var.location
  network       = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Model Armor Template
resource "google_model_armor_template" "template" {
  template_id = "${var.prefix}-template"
  location    = var.location
  project     = var.project_id
  depends_on  = [google_project_service.modelarmor]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "HIGH"
    }
    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "HIGH"
      }
    }
  }
  template_metadata {
    log_sanitize_operations = true
    log_template_operations = true
  }
}

# Secure Web Proxy (SWP) Policy
resource "google_network_security_gateway_security_policy" "swp_policy" {
  provider = google-beta
  name     = "${var.prefix}-swp-policy"
  location = var.location
  description = "Policy for SWP with allow-list"
  depends_on  = [google_project_service.networksecurity]
}

# SWP Rule for allow-list
resource "google_network_security_gateway_security_policy_rule" "allow_list" {
  provider = google-beta
  name     = "${var.prefix}-allow-rule"
  location = var.location
  gateway_security_policy = google_network_security_gateway_security_policy.swp_policy.name
  enabled  = true
  priority = 10
  basic_profile = "ALLOW"
  session_matcher = "host() == 'docs.cloud.google.com' || host() == 'github.com' || host().endsWith('.github.com') || host().endsWith('.githubusercontent.com') || host() == 'aiplatform.googleapis.com' || host().endsWith('.googleapis.com') || host() == 'cloudresourcemanager.googleapis.com' || host() == 'secretmanager.googleapis.com'"
}

# SWP Gateway
resource "google_network_services_gateway" "swp_gateway" {
  provider = google-beta
  name     = "${var.prefix}-swp-instance"
  location = var.location
  type     = "SECURE_WEB_GATEWAY"
  ports    = [8888]
  network  = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.swp_subnet.id
  gateway_security_policy = google_network_security_gateway_security_policy.swp_policy.id
  routing_mode = "EXPLICIT_ROUTING_MODE"
  addresses = ["10.10.10.5"] # Using a fixed IP from range
}

# Network Attachment for Egress Gateway
resource "google_compute_network_attachment" "psc_network_attachment" {
  name                  = "${var.prefix}-psc-network-attachment"
  region                = var.location
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.intf_subnet.id]
}

# # Agent Gateway - Ingress
# resource "google_network_services_agent_gateway" "ingress_gateway" {
#   provider = google-beta
#   name     = "${var.prefix}-ingress-gateway"
#   location = var.location
#   protocols = ["MCP"]
#   google_managed {
#     governed_access_path = "CLIENT_TO_AGENT"
#   }
#   depends_on = [google_project_service.networkservices]
# }
# 
# # Agent Gateway - Egress
# resource "google_network_services_agent_gateway" "egress_gateway" {
#   provider = google-beta
#   name     = "${var.prefix}-egress-gateway"
#   location = var.location
#   protocols = ["MCP"]
#   google_managed {
#     governed_access_path = "AGENT_TO_ANYWHERE"
#   }
#   depends_on = [google_project_service.networkservices]
#   network_config {
#     egress {
#       network_attachment = google_compute_network_attachment.psc_network_attachment.id
#     }
#   }
# }

module "lens_model_armor" {
  source = "./modules/lens_model_armor"

  project_id                              = var.project_id
  cloud_run_service_name                  = var.cloud_run_service_name
  security_google_chat_space              = var.security_google_chat_space
  security_google_chat_display_name       = var.security_google_chat_display_name
  security_notification_channel_ids       = var.security_notification_channel_ids
  enable_model_armor_security_alerts      = var.enable_model_armor_security_alerts
  prompt_injection_alert_threshold        = var.prompt_injection_alert_threshold
  prompt_injection_alert_window_seconds   = var.prompt_injection_alert_window_seconds
  prompt_injection_alert_duration_seconds = var.prompt_injection_alert_duration_seconds
}

module "gateway_observability" {
  source = "./modules/gateway_observability"

  project_id               = var.project_id
  demo_project_placeholder = var.demo_project_placeholder
  cloud_run_service_name   = var.cloud_run_service_name

  depends_on = [module.lens_model_armor]
}

module "org_observability" {
  count  = var.enable_org_observability ? 1 : 0
  source = "./modules/org_observability"

  metrics_scope_project_id           = coalesce(var.org_metrics_scope_project_id, var.project_id)
  monitored_project_ids              = var.org_monitored_project_ids
  scope_project_agent_dashboard_id   = module.agent_observability.dashboard_id
  scope_project_gateway_dashboard_id = module.gateway_observability.dashboard_id

  depends_on = [
    module.agent_observability,
    module.gateway_observability,
  ]
}

module "agent_observability" {
  source = "./modules/agent_observability"

  project_id                                  = var.project_id
  notification_channel_ids                    = var.notification_channel_ids
  slack_channel_name                          = var.slack_channel_name
  slack_auth_token                            = var.slack_auth_token
  slack_display_name                          = var.slack_display_name
  google_chat_space                           = var.google_chat_space
  google_chat_display_name                    = var.google_chat_display_name
  alert_email_address                         = var.alert_email_address
  alert_email_display_name                    = var.alert_email_display_name
  enable_token_alerts                         = var.enable_token_alerts
  enable_alert_baseline_spike                 = var.enable_alert_baseline_spike
  enable_alert_runaway_loop                   = var.enable_alert_runaway_loop
  enable_alert_project_surge                  = var.enable_alert_project_surge
  enable_alert_absolute_ceiling               = var.enable_alert_absolute_ceiling
  enable_alert_error_correlation              = var.enable_alert_error_correlation
  enable_alert_zero_traffic                   = var.enable_alert_zero_traffic
  project_token_surge_threshold               = var.project_token_surge_threshold
  project_surge_duration_seconds              = var.project_surge_duration_seconds
  per_agent_baseline_spike_percent            = var.per_agent_baseline_spike_percent
  per_agent_baseline_spike_duration_seconds   = var.per_agent_baseline_spike_duration_seconds
  per_agent_absolute_ceiling_threshold        = var.per_agent_absolute_ceiling_threshold
  per_agent_absolute_ceiling_duration_seconds = var.per_agent_absolute_ceiling_duration_seconds
  runaway_loop_call_threshold                 = var.runaway_loop_call_threshold
  runaway_loop_min_tokens                     = var.runaway_loop_min_tokens
  runaway_loop_duration_seconds               = var.runaway_loop_duration_seconds
  error_correlation_token_threshold           = var.error_correlation_token_threshold
  error_correlation_error_threshold           = var.error_correlation_error_threshold
  error_correlation_duration_seconds          = var.error_correlation_duration_seconds
  zero_traffic_duration_seconds               = var.zero_traffic_duration_seconds
  per_agent_token_spike_threshold             = var.per_agent_token_spike_threshold
  per_agent_spike_duration_seconds            = var.per_agent_spike_duration_seconds
}


