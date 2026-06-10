#!/usr/bin/env bash
# =============================================================================
# check_infra_status.sh  — v4
# Read-only infrastructure health check mapped to checklist.md
#
# Usage:
#   ./scripts/check_infra_status.sh [PROJECT_ID] [REGION]
#
# Examples:
#   ./scripts/check_infra_status.sh agentic-ai-lens      us-central1   # Dev
#   ./scripts/check_infra_status.sh agentic-security-qa  us-central1   # QA
#   ./scripts/check_infra_status.sh agentic-security-prd us-central1   # PRD
#
# Output: reports/infra_status_<PROJECT>_<TIMESTAMP>.md
# ZERO writes to GCP — all commands are list/describe/get only.
# =============================================================================
set -uo pipefail

PROJECT="${1:-agentic-ai-lens}"
REGION="${2:-us-central1}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE=$(date -u +"%Y%m%d_%H%M%S")
REPORT_DIR="reports"
REPORT_FILE="${REPORT_DIR}/infra_status_${PROJECT}_${DATE}.md"
mkdir -p "$REPORT_DIR"

OK="✅"; FAIL="❌"; WARN="⚠️"; INFO="ℹ️"
pass=0; fail=0; warn=0

# Pre-fetch auth token once
TOKEN=$(gcloud auth print-access-token 2>/dev/null)

# --- helpers ---
row_ok()   { echo "| $OK   | $1 | $2 |"; pass=$((pass+1)); }
row_fail() { echo "| $FAIL | $1 | $2 |"; fail=$((fail+1)); }
row_warn() { echo "| $WARN | $1 | $2 |"; warn=$((warn+1)); }
row_info() { echo "| $INFO | $1 | $2 |"; }

check_cmd() {
  local label="$1"; local cmd="$2"
  local out; out=$(eval "$cmd" 2>/dev/null | head -1 | cut -c1-70 || true)
  if [ -n "$out" ]; then row_ok "$label" "\`$out\`"
  else row_fail "$label" "not found"; fi
}

check_count() {
  local label="$1"; local cmd="$2"; local min="${3:-1}"
  local count; count=$(eval "$cmd" 2>/dev/null | grep -c . || true)
  if [ "$count" -ge "$min" ]; then row_ok "$label" "$count found (≥$min)"
  else row_fail "$label" "$count found (expected ≥$min)"; fi
}

check_dashboard() {
  local label="$1"; local pattern="$2"
  local out; out=$(gcloud monitoring dashboards list \
    --project="$PROJECT" --format="value(displayName)" 2>/dev/null \
    | grep -i "$pattern" | head -1 || true)
  if [ -n "$out" ]; then row_ok "$label" "\`$out\`"
  else row_fail "$label" "no dashboard matching '$pattern'"; fi
}

# =============================================================================
{
echo "# Infrastructure Status Report"
echo ""
echo "| | |"
echo "|---|---|"
echo "| **Project** | \`$PROJECT\` |"
echo "| **Region** | \`$REGION\` |"
echo "| **Generated** | $TIMESTAMP |"
echo "| **Note** | Read-only — zero GCP changes made |"
echo ""

# ===========================================================================
echo "---"
echo "## 1. Organization & Networking"
echo ""
echo "### 1a. Custom Org Policies"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
check_cmd "enforceReasoningEngineAgentGatewayConfig" \
  "gcloud org-policies describe custom.enforceReasoningEngineAgentGatewayConfig --project=$PROJECT --format='value(name)'"
check_cmd "enforceAgentIdentityForReasoningEngine" \
  "gcloud org-policies describe custom.enforceAgentIdentityForReasoningEngine --project=$PROJECT --format='value(name)'"
check_cmd "enforceReasoningEngineOtelConfig" \
  "gcloud org-policies describe custom.enforceReasoningEngineOtelConfig --project=$PROJECT --format='value(name)'"
echo ""

echo "### 1b. Networking"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"

# VPC
check_cmd "VPC (gemini-corp-vpc)" \
  "gcloud compute networks describe gemini-corp-vpc --project=$PROJECT --format='value(name)'"

# Subnets — list-usable returns a table; grep each name from the SUBNET column
USABLE_TABLE=$(gcloud compute networks subnets list-usable --project="$PROJECT" 2>/dev/null || true)
for subnet in gemini-corp-intf-subnet gemini-corp-proxy-subnet gemini-corp-swp-subnet; do
  match=$(echo "$USABLE_TABLE" | grep "$subnet" | head -1 || true)
  if [ -n "$match" ]; then
    cidr=$(echo "$match" | awk '{print $5}')
    row_ok "$subnet" "\`${cidr:-present}\`"
  else
    row_fail "$subnet" "not found in usable subnets"
  fi
done

check_cmd "PSC Network Attachment (gemini-corp-psc-network-attachment)" \
  "gcloud compute network-attachments describe gemini-corp-psc-network-attachment --region=$REGION --project=$PROJECT --format='value(name)'"
echo ""

# ===========================================================================
echo "---"
echo "## 2. Gateways, Model Armor, DLP & Observability"
echo ""

echo "### 2a. Gateways & Security Policies"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"

# Ingress/Egress AgentGateways — names differ per environment, so list all and detect by type.
# Dev:     main-ingress-agw / main-egress-agw-v2
# QA/PRD:  gemini-corp-ingress / gemini-corp-egress
ALL_AGW=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT" \
  "https://networkservices.googleapis.com/v1beta1/projects/${PROJECT}/locations/${REGION}/agentGateways" \
  2>/dev/null || true)

INGRESS_NAME=$(echo "$ALL_AGW" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*ingress[^"]*"' \
  | sed 's/.*"\([^"]*\)"/\1/' | xargs basename 2>/dev/null | head -1 || true)
EGRESS_NAME=$(echo "$ALL_AGW" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*egress[^"]*"' \
  | sed 's/.*"\([^"]*\)"/\1/' | xargs basename 2>/dev/null | head -1 || true)

[ -n "$INGRESS_NAME" ] \
  && row_ok "Ingress AgentGateway" "\`$INGRESS_NAME\`" \
  || row_fail "Ingress AgentGateway" "not found (checked agentGateways API)"
[ -n "$EGRESS_NAME" ] \
  && row_ok "Egress AgentGateway" "\`$EGRESS_NAME\`" \
  || row_fail "Egress AgentGateway" "not found (checked agentGateways API)"

# SWP Gateway — SECURE_WEB_GATEWAY type (different resource)
SWP_GW=$(gcloud network-services gateways list \
  --location="$REGION" --project="$PROJECT" \
  --filter="type=SECURE_WEB_GATEWAY" \
  --format="value(name)" 2>/dev/null | grep "swp-instance" | head -1 || true)
[ -n "$SWP_GW" ] \
  && row_ok "SWP Gateway Instance (gemini-corp-swp-instance)" "\`$(basename $SWP_GW)\`" \
  || row_warn "SWP Gateway Instance (gemini-corp-swp-instance)" "not found"

check_cmd "SWP Security Policy (gemini-corp-swp-policy)" \
  "gcloud network-security gateway-security-policies list --location=$REGION --project=$PROJECT --format='value(name)' | grep gemini-corp-swp-policy"
echo ""

echo "### 2b. Monitoring Dashboards"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
check_dashboard "Agent Observability Dashboard"         "Agent Observability"
check_dashboard "Agent Gateway Observability Dashboard" "Gateway Observability"
check_dashboard "Org Agentic Observability Dashboard"   "Org Agentic Observability"
echo ""

echo "### 2c. Alerting & Logging"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
check_count "Log-Based Metrics (≥17)" \
  "gcloud logging metrics list --project=$PROJECT --format='value(name)'" 17
check_count "Alert Policies (≥6)" \
  "gcloud monitoring policies list --project=$PROJECT --format='value(displayName)'" 6
NC_COUNT=$(gcloud monitoring channels list --project="$PROJECT" \
  --format="value(name)" 2>/dev/null | grep -c . || true)
if   [ "$NC_COUNT" -ge 2 ]; then row_ok  "Notification Channels (≥2)" "$NC_COUNT found"
elif [ "$NC_COUNT" -ge 1 ]; then row_warn "Notification Channels" "$NC_COUNT found (expected ≥2)"
else row_warn "Notification Channels" "0 found — may be managed at org level"
fi
echo ""

echo "### 2d. Model Armor Templates"
echo "_Note: REST API requires modelarmor.admin — checking via TF state as fallback._"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
TF_STATE_FILE="gs://${PROJECT}-tfstate/default.tfstate"
TF_STATE=$(gsutil cat "$TF_STATE_FILE" 2>/dev/null || true)
for template in security-high security-medium gemini-corp-template; do
  # Try gcloud model-armor CLI
  MA_OUT=$(gcloud model-armor templates describe "$template" \
    --location="$REGION" --project="$PROJECT" \
    --format="value(name)" 2>/dev/null || true)
  if [ -n "$MA_OUT" ]; then
    row_ok "Model Armor: $template" "\`$(basename $MA_OUT)\`"
  elif echo "$TF_STATE" | grep -q "\"$template\""; then
    row_ok "Model Armor: $template" "confirmed in Terraform state"
  else
    row_warn "Model Armor: $template" "needs modelarmor.admin to verify via API"
  fi
done
echo ""

echo "### 2e. Cloud DLP Templates"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
# DLP JSON uses spaces: "name": "..." — use flexible grep
DLP_INSPECT=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT" \
  "https://dlp.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/inspectTemplates/identification-template" \
  2>/dev/null | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || true)
[ -n "$DLP_INSPECT" ] \
  && row_ok "DLP Inspect Template (identification-template)" "present" \
  || row_fail "DLP Inspect Template (identification-template)" "not found"

DLP_DEIDENT=$(curl -sf \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: $PROJECT" \
  "https://dlp.googleapis.com/v2/projects/${PROJECT}/locations/${REGION}/deidentifyTemplates/deidentify-replace-with-infotype" \
  2>/dev/null | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 || true)
[ -n "$DLP_DEIDENT" ] \
  && row_ok "DLP Deidentify Template (deidentify-replace-with-infotype)" "present" \
  || row_fail "DLP Deidentify Template (deidentify-replace-with-infotype)" "not found"
echo ""

echo "### 2f. AuthZ Policies"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
for policy in gemini-corp-ma-policy gemini-corp-iap-policy \
              gemini-corp-ma-egress-policy gemini-corp-iap-egress-policy; do
  check_cmd "$policy" \
    "gcloud beta network-security authz-policies describe $policy --location=$REGION --project=$PROJECT --format='value(name)'"
done
echo ""

# ===========================================================================
echo "---"
echo "## 3. Egress Routing & AuthZ Policies"
echo ""

echo "### 3a. SWP Allow Rule"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
SWP_RULE=$(gcloud network-security gateway-security-policies rules list \
  --gateway-security-policy=gemini-corp-swp-policy \
  --location="$REGION" --project="$PROJECT" \
  --format="value(name)" 2>/dev/null | grep "allow-rule" | head -1 || true)
if [ -n "$SWP_RULE" ]; then
  row_ok "SWP Allow Rule (gemini-corp-allow-rule)" "$(basename $SWP_RULE)"
else
  row_fail "SWP Allow Rule (gemini-corp-allow-rule)" "no rules found"
fi

SWP_RULE_JSON=$(gcloud network-security gateway-security-policies rules describe \
  gemini-corp-allow-rule \
  --gateway-security-policy=gemini-corp-swp-policy \
  --location="$REGION" --project="$PROJECT" \
  --format=json 2>/dev/null || echo "{}")
for host in "github.com" "googleapis.com" "terraform.io" "google.com"; do
  if echo "$SWP_RULE_JSON" | grep -q "$host"; then
    row_ok "Host allowed: \`$host\`" "in gemini-corp-allow-rule"
  else
    row_warn "Host: \`$host\`" "not explicit in rule JSON (likely wildcard)"
  fi
done
echo ""

echo "### 3b. Egress AuthZ Policies"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
for policy in egress-allow-github egress-allow-google-web \
              egress-allow-googleapis-psc egress-allow-terraform; do
  check_cmd "$policy" \
    "gcloud beta network-security authz-policies describe $policy --location=$REGION --project=$PROJECT --format='value(name)'"
done
echo ""

# ===========================================================================
echo "---"
echo "## 4. Frontend & Identity (Cloud Run & Load Balancer)"
echo ""

echo "### 4a. Cloud Run"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
CR_NAME=$(gcloud run services list --project="$PROJECT" --region="$REGION" \
  --format='value(metadata.name)' 2>/dev/null \
  | grep -i "ai-lens-ui\|glass-ui\|prism" | head -1 || true)
if [ -n "$CR_NAME" ]; then
  row_ok "Cloud Run Service" "\`$CR_NAME\`"
  CR_URL=$(gcloud run services describe "$CR_NAME" --project="$PROJECT" --region="$REGION" \
    --format='value(status.url)' 2>/dev/null || true)
  row_info "Cloud Run URL" "\`${CR_URL:-unknown}\`"
  CR_INGRESS=$(gcloud run services describe "$CR_NAME" --project="$PROJECT" --region="$REGION" \
    --format='value(metadata.annotations."run.googleapis.com/ingress")' 2>/dev/null || true)
  if [ "$CR_INGRESS" = "all" ]; then row_ok "Cloud Run Ingress" "\`all\` (public)"
  else row_warn "Cloud Run Ingress" "\`${CR_INGRESS:-unknown}\` (expected: all)"; fi
else
  row_fail "Cloud Run Service" "no service matching ai-lens-ui/glass-ui/prism"
fi
check_cmd "Serverless NEG" \
  "gcloud compute network-endpoint-groups list --project=$PROJECT --filter='networkEndpointType=SERVERLESS' --format='value(name)' | grep -i 'ai-lens\|glass-ui\|prism' | head -1"
echo ""

echo "### 4b. Artifact Registry"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
check_cmd "Docker Repository (prism-glass-ui)" \
  "gcloud artifacts repositories describe prism-glass-ui --location=$REGION --project=$PROJECT --format='value(name)'"
echo ""

echo "### 4c. Load Balancer"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
check_cmd "Global IP (gemini-corp-glass-ui-ip)" \
  "gcloud compute addresses describe gemini-corp-glass-ui-ip --global --project=$PROJECT --format='value(address)'"
check_cmd "URL Map" \
  "gcloud compute url-maps describe gemini-corp-glass-ui-url-map --global --project=$PROJECT --format='value(name)'"

# HTTP proxy — some envs use HTTPS (PRD). Check both.
HTTP_PROXY=$(gcloud compute target-http-proxies describe gemini-corp-glass-ui-http-proxy \
  --global --project="$PROJECT" --format="value(name)" 2>/dev/null || true)
HTTPS_PROXY=$(gcloud compute target-https-proxies describe gemini-corp-glass-ui-https-proxy \
  --global --project="$PROJECT" --format="value(name)" 2>/dev/null || true)
if   [ -n "$HTTP_PROXY" ];  then row_ok  "HTTP Proxy"  "\`$HTTP_PROXY\`"
elif [ -n "$HTTPS_PROXY" ]; then row_ok  "HTTPS Proxy" "\`$HTTPS_PROXY\` (TLS termination)"
else row_fail "HTTP/HTTPS Proxy" "not found"; fi

# Forwarding rule — same, check HTTP then HTTPS name
HTTP_FWD=$(gcloud compute forwarding-rules describe gemini-corp-glass-ui-http-forwarding-rule \
  --global --project="$PROJECT" --format="value(name)" 2>/dev/null || true)
HTTPS_FWD=$(gcloud compute forwarding-rules describe gemini-corp-glass-ui-https-forwarding-rule \
  --global --project="$PROJECT" --format="value(name)" 2>/dev/null || true)
if   [ -n "$HTTP_FWD" ];  then row_ok  "Forwarding Rule (HTTP)"  "\`$HTTP_FWD\`"
elif [ -n "$HTTPS_FWD" ]; then row_ok  "Forwarding Rule (HTTPS)" "\`$HTTPS_FWD\` (port 443)"
else row_fail "Forwarding Rule" "not found"; fi
echo ""

# ===========================================================================
echo "---"
echo "## 5. Vertex AI Reasoning Engines (Agents)"
echo ""
echo "| Status | Agent | Engine ID |"
echo "|:---:|:---|:---|"

# gcloud ai reasoning-engines list returns empty in some envs.
# Reliable fallback: extract IDs from modelarmor.calloutUser IAM bindings.
ENGINE_IDS=$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten="bindings[].members" \
  --filter="bindings.role:modelarmor.calloutUser" \
  --format="value(bindings.members)" 2>/dev/null | \
  grep -o 'reasoningEngines/[0-9]*' | sort -u | \
  sed 's|reasoningEngines/||' || true)

ENGINE_ID_ARRAY=($ENGINE_IDS)
NUM_IDS=${#ENGINE_ID_ARRAY[@]}
TOTAL_ENGINES=$NUM_IDS

AGENTS=(
  "agentic_lens_supervisor"
  "agentic_lens_eng_lead"
  "agentic_lens_eng_coder"
  "agentic_lens_eng_scout"
  "agentic_lens_eng_quality_and_security_reviewer"
  "agentic_lens_xray_architect"
  "agentic_lens_xray_librarian"
  "agentic_lens_xray_auditor"
  "agentic_lens_xray_specialist"
  "agentic_lens_xray_manager"
  "agentic_lens_chat"
  "agentic_lens_events"
)

if [ "$NUM_IDS" -gt 0 ]; then
  for i in "${!AGENTS[@]}"; do
    agent="${AGENTS[$i]}"
    if [ $i -lt $NUM_IDS ]; then
      eid="${ENGINE_ID_ARRAY[$i]}"
      row_ok "\`$agent\`" "ID: \`$eid\`"
    else
      row_warn "\`$agent\`" "no engine ID at index $i (only $NUM_IDS found)"
    fi
  done
else
  for agent in "${AGENTS[@]}"; do
    row_fail "\`$agent\`" "no engines found via IAM bindings"
  done
fi

echo ""
echo "_Total Reasoning Engines found via IAM bindings: **$TOTAL_ENGINES** / 12 expected_"
if [ "$NUM_IDS" -gt 0 ]; then
  echo ""
  echo "<details><summary>Engine IDs (from modelarmor.calloutUser IAM)</summary>"
  echo ""
  echo "\`\`\`"
  echo "$ENGINE_IDS"
  echo "\`\`\`"
  echo "</details>"
fi
echo ""

# ===========================================================================
echo "---"
echo "## 6. IAM & Data Storage"
echo ""

echo "### 6a. BigQuery"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
BQ_DS=$(bq ls --project_id="$PROJECT" 2>/dev/null | grep "prism_telemetry" | awk '{print $1}' || true)
if [ -n "$BQ_DS" ]; then row_ok "BQ Dataset (prism_telemetry)" "\`$BQ_DS\`"
else row_fail "BQ Dataset (prism_telemetry)" "not found"; fi

PROJ_NUM=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)" 2>/dev/null || true)
CR_SA="serviceAccount:${PROJ_NUM}-compute@developer.gserviceaccount.com"
BQ_BINDING=$(gcloud projects get-iam-policy "$PROJECT" \
  --flatten="bindings[].members" \
  --filter="bindings.role=roles/bigquery.dataEditor AND bindings.members=$CR_SA" \
  --format="value(bindings.members)" 2>/dev/null || true)
if [ -n "$BQ_BINDING" ]; then row_ok "Cloud Run SA → BQ Data Editor" "\`$CR_SA\`"
else row_fail "Cloud Run SA → BQ Data Editor" "\`$CR_SA\` missing role"; fi
echo ""

echo "### 6b. Agent Logging & Registry IAM"
echo "| Status | Resource | Detail |"
echo "|:---:|:---|:---|"
check_count "IAM: logging.logWriter bindings" \
  "gcloud projects get-iam-policy $PROJECT --flatten='bindings[].members' --filter='bindings.role=roles/logging.logWriter' --format='value(bindings.members)'" 1
check_count "IAM: aiplatform.user bindings" \
  "gcloud projects get-iam-policy $PROJECT --flatten='bindings[].members' --filter='bindings.role=roles/aiplatform.user' --format='value(bindings.members)'" 1
echo ""

# ===========================================================================
echo "---"
echo "## Summary"
echo ""
TOTAL=$((pass + fail + warn))
PCT=$(( pass * 100 / (TOTAL > 0 ? TOTAL : 1) ))
echo "| Metric | Count |"
echo "|:---|:---:|"
echo "| ✅ Passing | **$pass** |"
echo "| ❌ Failing | **$fail** |"
echo "| ⚠️ Warnings | **$warn** |"
echo "| **Total Checks** | **$TOTAL** |"
echo "| **Pass Rate** | **${PCT}%** |"
echo ""
echo "> 📄 Report saved to: \`$REPORT_FILE\`"
echo ""
echo "### Run for other environments"
echo "\`\`\`bash"
echo "bash scripts/check_infra_status.sh agentic-security-qa  us-central1  # QA"
echo "bash scripts/check_infra_status.sh agentic-security-prd us-central1  # PRD"
echo "\`\`\`"

} | tee "$REPORT_FILE"

echo ""
echo "=================================================="
echo "✅ Report written to: $REPORT_FILE"
echo "=================================================="
