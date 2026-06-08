# Repository: agentic-governance

This repository manages the deployment, hardening, and verification of the secure multi-agentic system (Agentic Prism) and its associated gateways (Ingress/Egress, Secure Web Proxy, Model Armor).

---

## Architecture Status Summary

* **Dev Project**: `agentic-ai-lens` (direct-access development environment)
* **QA & Prod Projects**: Restricted environments managed strictly via Git-triggered CI/CD
* **Region**: `us-central1`
* **Infrastructure**: Managed via Terraform IaC ([main.tf](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/main.tf))
* **Organization Policies Enforced**:
  1. **IAM Roles**: Restricted strictly to SPIFFE-based Agent Identities (`custom.enforceAgentIdentityOnly`).
  2. **Agent Engine Config**: Enforces secure configuration (`custom.enforceSecureAgentEngineConfig`).
  3. **Dual-Gateway Config**: Enforces that all reasoning engines specify **both** Ingress and Egress gateways in deployment spec (`custom.enforceReasoningEngineAgentGatewayConfig`).

---

## Deployment & CI/CD Pipelines

All QA and Production deployments are triggered manually through Google Cloud Build using the [cloudbuild.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/cloudbuild.yaml) file at the root of this repository.

* **Trigger Location**: Google Cloud Console > Cloud Build > Triggers
* **Authentication**: Secured via Workload Identity and Secret Manager (`github-pat-token`)
* **Pipeline Sequence**:
  1. Terraform Apply (Infra, Dashboards, Org Policy bindings)
  2. Vertex AI Agent Engine Deployment (deploying all 12 Reasoning Engines)
  3. Glass UI Docker build & Cloud Run VPC-egress deployment

