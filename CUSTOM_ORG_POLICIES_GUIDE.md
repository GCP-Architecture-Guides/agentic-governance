# Guide: Custom Organization Policies for Secure Agentic Perimeter

This document explains the custom organization policies implemented in the `agentic-security-dev` project to enforce security best practices for Vertex AI Agent Engines (Reasoning Engines) and IAM role bindings.

## Overview

To achieve the goal of a production-hardened Gemini Agent deployment, we established strict guardrails using Google Cloud Organization Policy Service. We defined custom constraints to enforce specific configurations that are not covered by predefined organization policies.

---

## Policy 1: Enforce Agent Identity for IAM Roles

### Goal
Restricts IAM role bindings to Agent Identities only, denying standard Service Accounts, users, and groups. This ensures that only principals following the SPIFFE-based Agent Identity pattern can be granted permissions within the scope.

### Constraint Definition
**File:** [enforce-agent-identity.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/enforce-agent-identity.yaml)

```yaml
name: organizations/873180247571/customConstraints/custom.enforceAgentIdentityOnly
resourceTypes:
- iam.googleapis.com/AllowPolicy
methodTypes:
- CREATE
- UPDATE
condition: >
  resource.bindings.exists(b, b.members.exists(m, !MemberSubjectStartsWith(m, ["principal://agents.", "principalSet://agents."])))
actionType: DENY
displayName: Enforce Agent Identity for IAM Roles
description: Only Agent Identities can be granted IAM roles. Other principal types are not allowed.
```

### Policy Definition
**File:** [policy-enforce-agent-identity.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/policy-enforce-agent-identity.yaml)

```yaml
name: organizations/873180247571/policies/custom.enforceAgentIdentityOnly
spec:
  rules:
  - enforce: true
```

### How to Apply

1.  **Set the Custom Constraint**:
    ```bash
    gcloud org-policies set-custom-constraint enforce-agent-identity.yaml
    ```
2.  **Enforce the Policy**:
    ```bash
    gcloud org-policies set-policy policy-enforce-agent-identity.yaml
    ```

### Verification
We verified this policy by attempting to grant `roles/viewer` to the default compute service account. The operation was successfully denied with a policy violation error.

---

## Policy 2: Enforce Secure Configuration for Agent Engines

### Goal
Ensures that all Vertex AI Agent Engines (ReasoningEngine) are deployed with:
1.  `AGENT_IDENTITY` enabled.
2.  Specific environment variables for telemetry and OpenTelemetry set to required values.

### Constraint Definition
**File:** [enforce-secure-agent-engine.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/enforce-secure-agent-engine.yaml)

```yaml
name: organizations/873180247571/customConstraints/custom.enforceSecureAgentEngineConfig
resourceTypes:
- aiplatform.googleapis.com/ReasoningEngine
methodTypes:
- CREATE
- UPDATE
condition: >-
  resource.spec.identityType != 'AGENT_IDENTITY' ||
  !has(resource.spec.deploymentSpec.env) ||
  !resource.spec.deploymentSpec.env.exists(e, e.name == 'GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY' && e.value == 'true') ||
  !resource.spec.deploymentSpec.env.exists(e, e.name == 'OTEL_SEMCONV_STABILITY_OPT_IN' && e.value == 'gen_ai_latest_experimental') ||
  !resource.spec.deploymentSpec.env.exists(e, e.name == 'OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT' && e.value == 'EVENT_ONLY')
actionType: DENY
displayName: Enforce Secure Configuration for Agent Engines
description: Agent Engines must use AGENT_IDENTITY and have specific telemetry environment variables set to the required values in deploymentSpec.env.
```

### Policy Definition
**File:** [policy-enforce-secure-agent-engine.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/policy-enforce-secure-agent-engine.yaml)

```yaml
name: organizations/873180247571/policies/custom.enforceSecureAgentEngineConfig
spec:
  rules:
  - enforce: true
```

### How to Apply

1.  **Set the Custom Constraint**:
    ```bash
    gcloud org-policies set-custom-constraint enforce-secure-agent-engine.yaml
    ```
2.  **Enforce the Policy**:
    ```bash
    gcloud org-policies set-policy policy-enforce-secure-agent-engine.yaml
    ```

### Verification
We verified this policy by creating three test payloads, each violating one of the specific conditions (Identity, Telemetry, OTEL). All three attempts were successfully blocked by the policy.

---

## Policy 3: Enforce Ingress and Egress Gateways for Agent Engines

### Goal
Mandates that all Vertex AI Agent Engines (Reasoning Engines) deployed in the project must specify **both** Ingress (`clientToAgentConfig`) and Egress (`agentToAnywhereConfig`) gateway configurations in their deployment spec. This enforces a dual-gate security perimeter.

### Constraint Definition
**File:** [enforce-reasoning-engine-agent-gateway-config.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/enforce-reasoning-engine-agent-gateway-config.yaml)

```yaml
name: organizations/873180247571/customConstraints/custom.enforceReasoningEngineAgentGatewayConfig
resourceTypes:
- aiplatform.googleapis.com/ReasoningEngine
methodTypes:
- CREATE
- UPDATE
condition: >-
  !has(resource.spec.deploymentSpec) ||
  !has(resource.spec.deploymentSpec.agentGatewayConfig) ||
  !has(resource.spec.deploymentSpec.agentGatewayConfig.clientToAgentConfig) ||
  !has(resource.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig)
actionType: DENY
displayName: Enforce Ingress and Egress Gateway Configuration for Reasoning Engines
description: Reasoning Engines must be deployed with both Ingress (clientToAgentConfig) and Egress (agentToAnywhereConfig) gateways defined in deploymentSpec.
```

### Policy Definition
**File:** [policy-enforce-reasoning-engine-agent-gateway-config.yaml](file:///usr/local/google/home/manishkgaur/Desktop/Workspace/Agent-gateway/policy-enforce-reasoning-engine-agent-gateway-config.yaml)

```yaml
name: organizations/873180247571/policies/custom.enforceReasoningEngineAgentGatewayConfig
spec:
  rules:
  - enforce: true
```

### How to Apply

1. **Set the Custom Constraint**:
   ```bash
   gcloud org-policies set-custom-constraint enforce-reasoning-engine-agent-gateway-config.yaml
   ```
2. **Enforce the Policy**:
   ```bash
   gcloud org-policies set-policy policy-enforce-reasoning-engine-agent-gateway-config.yaml
   ```

### Verification
We verified this policy by:
* **Blocked Path**: Attempting to update the reasoning engine with only the Ingress Gateway (`clientToAgentConfig`) was successfully denied with a custom organization policy violation.
* **Allowed Path**: Attempting to update with both Ingress and Egress gateway configurations successfully bypassed the organization policy schema checks, creating the long-running operation.

---

## Lessons Learned & Troubleshooting

### 1. API Enablement
Ensure that the `orgpolicy.googleapis.com` API is enabled on the project before attempting to set custom constraints or policies.

### 2. CEL Syntax and Functions
*   **Undeclared Reference to 'policy'**: In conditions for `iam.googleapis.com/AllowPolicy`, reference the resource as `resource` rather than `policy`.
*   **Disallowed String Operators**: Direct use of string operators like `startsWith` and regex `.matches()` was disallowed in some contexts. We resolved this by using the supported helper function `MemberSubjectStartsWith(member, [prefixes])`.

### 3. Schema Knowledge
For `aiplatform.googleapis.com/ReasoningEngine`, environment variables are defined as a list of objects in `deploymentSpec.env` with `name` and `value` fields, rather than a map structure. The CEL condition was updated to iterate over the list using the `exists` macro.
