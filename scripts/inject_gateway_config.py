#!/usr/bin/env python3
"""
Inject agent_gateway_config into all agent .agent_engine_config.json files.

Required by org policy:
  customConstraints/custom.enforceReasoningEngineAgentGatewayConfig
  "Reasoning Engines must be deployed with both Ingress (clientToAgentConfig)
   and Egress (agentToAnywhereConfig) gateways defined in deploymentSpec."

.agent_engine_config.json is gitignored so the git clone in Cloud Build step-0
wipes all agent configs. This script recreates/updates them with the correct
gateway resource names before deploy.sh runs.

Usage:
  python3 scripts/inject_gateway_config.py <ingress_gw_resource> <egress_gw_resource> [agents_dir]

Example:
  python3 scripts/inject_gateway_config.py \
    projects/agentic-security-prd/locations/us-central1/agentGateways/gemini-corp-ingress-gateway \
    projects/agentic-security-prd/locations/us-central1/agentGateways/gemini-corp-egress-gateway \
    agentic-lens/agents
"""
import json
import glob
import os
import sys


DEFAULT_AGENT_CFG = {
    "identity_type": "AGENT_IDENTITY",
    "min_instances": 1,
    "max_instances": 2,
    "resource_limits": {"cpu": "4", "memory": "8Gi"},
    "container_concurrency": 2,
}


def main():
    if len(sys.argv) < 3:
        print("Usage: inject_gateway_config.py <ingress> <egress> [agents_dir]", file=sys.stderr)
        sys.exit(1)

    ingress = sys.argv[1]
    egress = sys.argv[2]
    agents_dir = sys.argv[3] if len(sys.argv) > 3 else "agentic-lens/agents"

    gateway_cfg = {
        "client_to_agent_config": {"agent_gateway": ingress},
        "agent_to_anywhere_config": {"agent_gateway": egress},
    }

    count = 0
    for agent_dir in sorted(glob.glob(os.path.join(agents_dir, "*/"))):
        agent = os.path.basename(agent_dir.rstrip("/"))
        if "_staged" in agent:
            continue
        cfg_path = os.path.join(agent_dir, ".agent_engine_config.json")
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            cfg = dict(DEFAULT_AGENT_CFG)
        cfg["agent_gateway_config"] = gateway_cfg
        with open(cfg_path, "w") as f:
            json.dump(cfg, f, indent=2)
        print(f"  gateway config set: {agent}")
        count += 1

    print(f"Done. Injected gateway config into {count} agents.")


if __name__ == "__main__":
    main()
