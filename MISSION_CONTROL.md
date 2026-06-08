# Mission: Secure Agentic Perimeter

**Goal:** Deploy a production-hardened Gemini Agent using Agent Identity (SPIFFE-based) rather than traditional service accounts.

**Traffic Control:** All ingress must pass through Agent Gateway (Ingress) with Model Armor for prompt injection shielding. All egress must pass through Agent Gateway (Egress).

**Domain Governance:** Outbound internet traffic must be funneled through Secure Web Proxy (SWP) to enforce a strict allow-list (e.g., github.com, google.com).

**Observability:** The entire chain must emit OpenTelemetry traces for end-to-end visibility in Cloud Trace.

## Status (as of May 20, 2026)
- **Ingress/Egress Gateways**: Egress gateway integration is pending project-level early access activation, while Ingress gateway routing is active and verified.
- **Agent Deployment**: Deployed via Python SDK/REST.
  - **Reasoning Engine ID**: `4058977466062995456`
- **Organization Policies**:
  - **IAM Roles**: Restricted to SPIFFE-based Agent Identities only. Verified.
  - **Agent Engine Config**: Enforced secure configuration (Identity and telemetry env vars). Verified.
  - **Dual-Gateway Config**: Enforces Dual Gateways. Verified.
- **Next Steps**:
  - Obtain early-access whitelisting approval for **Egress Gateway PSC attachments** to reconcile Egress network interfaces.
