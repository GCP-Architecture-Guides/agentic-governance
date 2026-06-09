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

resource "google_project_service" "artifactregistry" {
  service = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dlp" {
  service = "dlp.googleapis.com"
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "prism_glass_ui" {
  location      = var.location
  repository_id = "prism-glass-ui"
  description   = "Docker repository for Glass UI"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
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
  ip_cidr_range = "10.10.10.0/24"
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

# Agent Gateway - Ingress
resource "google_network_services_agent_gateway" "ingress_gateway" {
  provider = google-beta
  name     = "${var.prefix}-ingress-gateway"
  location = var.location
  protocols = ["MCP"]
  google_managed {
    governed_access_path = "CLIENT_TO_AGENT"
  }
  depends_on = [google_project_service.networkservices]
}

# Agent Gateway - Egress
resource "google_network_services_agent_gateway" "egress_gateway" {
  provider = google-beta
  name     = "${var.prefix}-egress-gateway"
  location = var.location
  protocols = ["MCP"]
  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }
  depends_on = [google_project_service.networkservices]
  network_config {
    egress {
      network_attachment = google_compute_network_attachment.psc_network_attachment.id
    }
  }
}

# --- DLP Inspect Template ---
resource "google_data_loss_prevention_inspect_template" "identification_template" {
  parent       = "projects/${var.project_id}/locations/${var.location}"
  template_id  = "identification-template"
  display_name = "Identification template"
  description  = "Detects SSN, email, GCP credentials, credit card, medical and FDA/ICD codes."
  depends_on   = [google_project_service.dlp]

  inspect_config {
    min_likelihood = "POSSIBLE"
    include_quote  = true

    info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
    info_types { name = "EMAIL_ADDRESS" }
    info_types { name = "GCP_API_KEY" }
    info_types { name = "GCP_CREDENTIALS" }
    info_types { name = "CREDIT_CARD_NUMBER" }
    info_types { name = "BLOOD_TYPE" }
    info_types { name = "FDA_CODE" }
    info_types { name = "ICD10_CODE" }
    info_types { name = "ICD9_CODE" }
    info_types { name = "MEDICAL_TERM" }
  }
}

# --- DLP Deidentify Template ---
resource "google_data_loss_prevention_deidentify_template" "deidentify_template" {
  parent       = "projects/${var.project_id}/locations/${var.location}"
  template_id  = "deidentify-replace-with-infotype"
  display_name = "Deidentify replace with info type"
  description  = "Replaces sensitive text with the info type name (e.g. [EMAIL_ADDRESS])."
  depends_on   = [google_project_service.dlp]

  deidentify_config {
    info_type_transformations {
      transformations {
        info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
        info_types { name = "EMAIL_ADDRESS" }
        info_types { name = "GCP_API_KEY" }
        info_types { name = "GCP_CREDENTIALS" }
        info_types { name = "CREDIT_CARD_NUMBER" }
        info_types { name = "BLOOD_TYPE" }
        info_types { name = "FDA_CODE" }
        info_types { name = "ICD10_CODE" }
        info_types { name = "ICD9_CODE" }
        info_types { name = "MEDICAL_TERM" }

        primitive_transformation {
          replace_with_info_type_config = true
        }
      }
    }
  }
}

# --- Model Armor Templates ---
resource "google_model_armor_template" "security_medium" {
  template_id = "security-medium"
  location    = var.location
  project     = var.project_id
  depends_on  = [google_project_service.modelarmor]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "MEDIUM_AND_ABOVE"
    }
    sdp_settings {
      basic_config {
        filter_enforcement = "ENABLED"
      }
    }
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "MEDIUM_AND_ABOVE"
      }
    }
  }
  template_metadata {
    log_sanitize_operations = true
    log_template_operations = true
  }
}

resource "google_model_armor_template" "security_high" {
  template_id = "security-high"
  location    = var.location
  project     = var.project_id
  depends_on  = [google_project_service.modelarmor, google_data_loss_prevention_inspect_template.identification_template, google_data_loss_prevention_deidentify_template.deidentify_template]

  filter_config {
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "HIGH"
    }
    sdp_settings {
      advanced_config {
        inspect_template    = google_data_loss_prevention_inspect_template.identification_template.id
        deidentify_template = google_data_loss_prevention_deidentify_template.deidentify_template.id
      }
    }
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
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

# --- Authz Extensions ---
resource "google_network_services_authz_extension" "ma_extension" {
  provider    = google-beta
  name        = "${var.prefix}-ma-extension"
  location    = var.location
  project     = var.project_id
  service     = "modelarmor.us-central1.rep.googleapis.com"
  timeout     = "1s"
  wire_format = "EXT_AUTHZ_GRPC"

  metadata = {
    model_armor_settings = jsonencode([
      {
        response_template_id = "projects/${var.project_id}/locations/${var.location}/templates/security-high"
        request_template_id  = "projects/${var.project_id}/locations/${var.location}/templates/security-high"
      }
    ])
  }

  depends_on = [google_project_service.networkservices, google_model_armor_template.security_high]
}

resource "google_network_services_authz_extension" "iap_extension" {
  provider    = google-beta
  name        = "${var.prefix}-iap-extension"
  location    = var.location
  project     = var.project_id
  service     = "iap.googleapis.com"
  timeout     = "1s"
  wire_format = "EXT_AUTHZ_GRPC"

  depends_on = [google_project_service.networkservices]
}

# --- Ingress Authz Policies ---
resource "google_network_security_authz_policy" "ingress_ma_policy" {
  provider       = google-beta
  name           = "${var.prefix}-ma-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension.id]
    }
  }
}

resource "google_network_security_authz_policy" "ingress_iap_policy" {
  provider       = google-beta
  name           = "${var.prefix}-iap-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.iap_extension.id]
    }
  }
}

# --- Egress Authz Policies ---
resource "google_network_security_authz_policy" "egress_ma_policy" {
  provider       = google-beta
  name           = "${var.prefix}-ma-egress-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension.id]
    }
  }

  http_rules {
    to {
      operations {
        hosts { suffix = ".aiplatform.googleapis.com" }
        hosts { suffix = ".aiplatform.googleapis.com:443" }
        hosts { suffix = "-aiplatform.googleapis.com" }
        hosts { suffix = "-aiplatform.googleapis.com:443" }
        hosts { suffix = "aiplatform.googleapis.com" }
        hosts { suffix = "aiplatform.googleapis.com:443" }

        paths {
          contains    = "generatecontent"
          ignore_case = true
        }
        paths {
          contains    = "query"
          ignore_case = true
        }
        paths {
          contains    = "streamquery"
          ignore_case = true
        }
      }
    }
  }
}

resource "google_network_security_authz_policy" "egress_iap_policy" {
  provider       = google-beta
  name           = "${var.prefix}-iap-egress-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.iap_extension.id]
    }
  }

  http_rules {
    to {
      operations {
        hosts { suffix = ".internal-peer-service.corp" }
        hosts { suffix = ".internal-peer-service.corp:443" }
      }
    }
  }
}

# --- Egress Allowed Domain Policies ---
resource "google_network_security_authz_policy" "egress_allow_googleapis" {
  provider       = google-beta
  name           = "egress-allow-googleapis-psc"
  location       = var.location
  project        = var.project_id
  action         = "ALLOW"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  http_rules {
    to {
      operations {
        hosts { suffix = ".googleapis.com" }
        hosts { suffix = ".googleapis.com:443" }
        hosts { exact = "240.0.0.2" }
        hosts { exact = "240.0.0.2:443" }
      }
    }
  }
}

resource "google_network_security_authz_policy" "egress_allow_google_web" {
  provider       = google-beta
  name           = "egress-allow-google-web"
  location       = var.location
  project        = var.project_id
  action         = "ALLOW"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  http_rules {
    to {
      operations {
        hosts { suffix = ".google.com" }
        hosts { suffix = ".google.com:443" }
        hosts { exact = "google.com" }
        hosts { exact = "google.com:443" }
      }
    }
  }
}

resource "google_network_security_authz_policy" "egress_allow_github" {
  provider       = google-beta
  name           = "egress-allow-github"
  location       = var.location
  project        = var.project_id
  action         = "ALLOW"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  http_rules {
    to {
      operations {
        hosts { exact = "raw.githubusercontent.com" }
        hosts { exact = "raw.githubusercontent.com:443" }
        hosts { exact = "github.com" }
        hosts { exact = "github.com:443" }
        hosts { exact = "api.github.com" }
        hosts { exact = "api.github.com:443" }
      }
    }
  }
}

resource "google_network_security_authz_policy" "egress_allow_terraform" {
  provider       = google-beta
  name           = "egress-allow-terraform"
  location       = var.location
  project        = var.project_id
  action         = "ALLOW"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  http_rules {
    to {
      operations {
        hosts { suffix = ".terraform.io" }
        hosts { suffix = ".terraform.io:443" }
        hosts { exact = "terraform.io" }
        hosts { exact = "terraform.io:443" }
      }
    }
  }
}


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

# --- Data Sources ---
data "google_project" "project" {}

# --- Serverless NEG ---
resource "google_compute_region_network_endpoint_group" "glass_ui_neg" {
  name                  = "${var.prefix}-glass-ui-neg"
  region                = var.location
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = var.cloud_run_service_name
  }
}

# --- Global Backend Service ---
resource "google_compute_backend_service" "glass_ui_backend" {
  name                  = "${var.prefix}-glass-ui-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"

  backend {
    group = google_compute_region_network_endpoint_group.glass_ui_neg.id
  }

  dynamic "iap" {
    for_each = var.iap_client_id != "" && var.iap_client_secret != "" ? [1] : []
    content {
      enabled              = true
      oauth2_client_id     = var.iap_client_id
      oauth2_client_secret = var.iap_client_secret
    }
  }
}

# --- URL Map ---
resource "google_compute_url_map" "glass_ui_url_map" {
  name            = "${var.prefix}-glass-ui-url-map"
  default_service = google_compute_backend_service.glass_ui_backend.id
}

# --- Managed SSL Certificate ---
resource "google_compute_managed_ssl_certificate" "glass_ui_cert" {
  count = var.domain != "" ? 1 : 0
  name  = "${var.prefix}-glass-ui-cert"

  managed {
    domains = [var.domain]
  }
}

# --- Target Proxies ---
resource "google_compute_target_https_proxy" "glass_ui_https_proxy" {
  count            = var.domain != "" ? 1 : 0
  name             = "${var.prefix}-glass-ui-https-proxy"
  url_map          = google_compute_url_map.glass_ui_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.glass_ui_cert[0].id]
}

resource "google_compute_target_http_proxy" "glass_ui_http_proxy" {
  count   = var.domain == "" ? 1 : 0
  name    = "${var.prefix}-glass-ui-http-proxy"
  url_map = google_compute_url_map.glass_ui_url_map.id
}

# --- Global Forwarding Rules ---
resource "google_compute_global_address" "glass_ui_ip" {
  name = "${var.prefix}-glass-ui-ip"
}

resource "google_compute_global_forwarding_rule" "glass_ui_https_forwarding_rule" {
  count                 = var.domain != "" ? 1 : 0
  name                  = "${var.prefix}-glass-ui-https-forwarding-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.glass_ui_https_proxy[0].id
  ip_address            = google_compute_global_address.glass_ui_ip.address
}

resource "google_compute_global_forwarding_rule" "glass_ui_http_forwarding_rule" {
  count                 = var.domain == "" ? 1 : 0
  name                  = "${var.prefix}-glass-ui-http-forwarding-rule"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.glass_ui_http_proxy[0].id
  ip_address            = google_compute_global_address.glass_ui_ip.address
}

# --- Project IAM Policy for IAP invoker ---
resource "google_project_iam_member" "iap_invoker_project" {
  count   = var.iap_client_id != "" && var.iap_client_secret != "" ? 1 : 0
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-iap.iam.gserviceaccount.com"
}


