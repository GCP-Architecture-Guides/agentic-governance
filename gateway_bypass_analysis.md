# Ingress/Egress Gateway Model Armor Bypass Analysis & Fix

This document explains how the UI-to-Chat routing bypassed the Ingress/Egress Gateway Model Armor enforcement in the network workflow, and details the "Query via MCP" approach implemented to resolve this vulnerability.

---

## The Bypass Mechanism

### 1. Ingress Bypass (SDK Control-Plane Routing)
* **Vulnerability**: The Glass UI backend (`agent_engine_client.py`) uses the standard Vertex AI SDK (`ReasoningEngine.query()` or `stream_query()`). 
* **Mechanism**: When instantiating `ReasoningEngine(engine_id)` using the standard resource ID (`projects/{project}/locations/{location}/reasoningEngines/{id}`), the SDK directly targets the Google Cloud AI Platform control plane endpoint:
  `https://us-central1-aiplatform.googleapis.com/v1alpha/projects/{project}/locations/{location}/reasoningEngines/{id}:streamQuery`
* **Result**: Because the SDK uses the standard control-plane path rather than the proxy virtual path, it bypasses the edge Ingress Gateway (`main-ingress-agw`) entirely. Therefore, the Ingress Gateway's Model Armor policy (`gemini-corp-ma-policy`) is never triggered.

### 2. Egress Bypass (Egress Policy Path Mismatch)
* **Vulnerability**: Outbound API calls from the Glass UI container are intercepted and rewritten to the Gateway private IP (`240.0.0.2:443`) via the custom process-level bootstrap (`sitecustomize.py`).
* **Mechanism**: The requests hit the gateway interface `240.0.0.2` and are handled as outbound egress traffic directed at Google APIs (routed through the Egress Gateway `main-egress-agw-v2`).
* **Result**: However, the active egress security policy (`gemini-corp-ma-egress-policy`) only filters and intercepts paths matching `generateContent` (for direct Gemini LLM calls). Since Reasoning Engine queries use the gRPC service `/google.cloud.aiplatform.v1.ReasoningEngineService/StreamQuery` (or HTTP suffix `:query` / `:streamQuery`), they pass through the Egress Gateway unfiltered.

---

## The Fix: Query via MCP Approach

To close this bypass, we route all queries targeting reasoning engines through the virtual agent proxy endpoint exposed by the Ingress Gateway:

### 1. Virtual Ingress Gateway Endpoint
The regional Ingress Gateway (`main-ingress-agw`) binds the Agent Registry and exposes a virtual agent proxy endpoint for each reasoning engine:
`https://us-central1-aiplatform.googleapis.com/v1alpha/projects/{project}/locations/{location}/agentGateways/main-ingress-agw/agents/{agent_id}/a2a`

### 2. Direct HTTPS/REST A2A Protocol Routing
Since the standard `ReasoningEngine` SDK class enforces rigid validation on resource IDs (restricting them to paths containing `reasoningEngines` and failing with a `ValueError` for the `agentGateways` path), we perform direct REST calls using the A2A endpoint structure:
* **Protocol**: MCP/A2A (Model Context Protocol / Agent-to-Agent).
* **Endpoint**: `POST https://us-central1-aiplatform.googleapis.com/v1alpha/projects/{project}/locations/{location}/agentGateways/main-ingress-agw/agents/{agent_id}/a2a`
* **Payload**:
  ```json
  {
    "message": {
      "role": "user",
      "parts": [
        {
          "text": "<prompt>"
        }
      ]
    }
  }
  ```
* **Authentication**: Explicitly retrieves the Application Default Credentials (ADC) token and adds it to the HTTP request headers:
  `Authorization: Bearer <token>`
* **Edge Interception**: Because the request explicitly calls the `agentGateways/main-ingress-agw` virtual path, the gateway intercepts the traffic, maps it to the Ingress Gateway security policy, and runs the edge Model Armor template (`security-high`/`security-medium`) on the payload before proxying it to the backend Reasoning Engine.
