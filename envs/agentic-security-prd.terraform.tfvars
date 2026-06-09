project_id = "agentic-security-prd"
region     = "us-central1"
prefix     = "gemini-corp"
domain     = "agent-security.manishkgaur.demo.altostrat.com"
cloud_run_service_name = "prd-ai-lens-ui"

# Org-level Observability Dashboard — all org projects scoped to this PRD hub
enable_org_observability  = true
org_metrics_scope_project_id = "agentic-security-prd"
org_monitored_project_ids = [
  "agentic-security-qa",
  "agentic-ai-lens",
  "agentic-publication",
  "agentic-prismv333",
  "the-code-foundry",
  "code-factory-498812",
  "agentic-lens",
  "agentic-security-dev",
  "agent-gateway-demo"
]
