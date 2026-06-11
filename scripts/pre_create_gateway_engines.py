#!/usr/bin/env python3
"""
pre_create_gateway_engines.py

Pre-creates lightweight Reasoning Engines via the Vertex AI REST API with
both clientToAgentConfig and agentToAnywhereConfig in the deploymentSpec.

WHY THIS IS NEEDED:
  The org policy customConstraints/custom.enforceReasoningEngineAgentGatewayConfig
  requires gateway config in deploymentSpec on every CREATE operation.
  The ADK CLI uses the old vertexai.agent_engines gRPC SDK which does NOT
  support setting deploymentSpec.clientToAgentConfig / agentToAnywhereConfig.
  The REST API /v1beta1/reasoningEngines DOES accept these fields.

STRATEGY:
  1. Pre-CREATE a lightweight engine (no packageSpec) with gateway config.
     → Org policy sees the gateway config → PASSES.
  2. ADK then runs `adk deploy agent_engine --agent_engine_id=<id>` to UPDATE
     the engine with actual agent code.
     → The UPDATE only sends fields in the update_mask (not gateway config),
       so gateway config is PRESERVED from step 1.
     → Org policy on UPDATE sees the existing gateway config → PASSES.

Usage:
  python3 pre_create_gateway_engines.py \\
    --project agentic-security-prd \\
    --location us-central1 \\
    --ingress projects/.../gemini-corp-ingress-gateway \\
    --egress  projects/.../gemini-corp-egress-gateway \\
    --agents-dir agentic-lens/agents \\
    --out-dir /tmp/engine_ids  # writes <agent>.engine_id per agent
"""
import argparse
import json
import os
import subprocess
import sys
import time
import glob


def get_access_token() -> str:
    result = subprocess.run(
        ["gcloud", "auth", "print-access-token"],
        capture_output=True, text=True, check=True
    )
    return result.stdout.strip()


def list_engines(project: str, location: str, token: str) -> dict:
    """Returns {displayName: {name, state, ...}} for all existing engines."""
    import urllib.request
    url = (
        f"https://{location}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{project}/locations/{location}/reasoningEngines"
        f"?pageSize=200"
    )
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    engines = {}
    for e in data.get("reasoningEngines", []):
        dn = e.get("displayName", "")
        if dn:
            engines[dn] = e
    return engines


def create_lightweight_engine(
    project: str, location: str, token: str,
    display_name: str, ingress: str, egress: str
) -> dict:
    """Creates a lightweight engine (no packageSpec) with gateway config.
    Returns the operation JSON."""
    import urllib.request, urllib.error
    url = (
        f"https://{location}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{project}/locations/{location}/reasoningEngines"
    )
    body = {
        "displayName": display_name,
        "spec": {
            "deploymentSpec": {
                "clientToAgentConfig": {
                    "agentGateway": ingress
                },
                "agentToAnywhereConfig": {
                    "agentGateway": egress
                }
            }
        }
    }
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        url, data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json"
        },
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"  ERROR {e.code}: {err_body}", file=sys.stderr)
        raise


def wait_for_operation(
    project: str, location: str, token: str,
    operation_name: str, timeout: int = 300
) -> dict:
    """Polls a Vertex AI LRO until complete. Returns the response resource."""
    import urllib.request
    deadline = time.time() + timeout
    while time.time() < deadline:
        url = f"https://{location}-aiplatform.googleapis.com/v1/{operation_name}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            op = json.loads(resp.read())
        if op.get("done"):
            if "error" in op:
                raise RuntimeError(f"Operation failed: {op['error']}")
            return op.get("response", {})
        print(f"    waiting... ({int(deadline - time.time())}s left)", flush=True)
        time.sleep(10)
    raise TimeoutError(f"Operation {operation_name} timed out after {timeout}s")


def extract_engine_id_from_name(resource_name: str) -> str:
    """Extract numeric engine ID from full resource name."""
    return resource_name.split("/")[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--location", default="us-central1")
    parser.add_argument("--ingress", required=True, help="Full resource name of ingress gateway")
    parser.add_argument("--egress", required=True, help="Full resource name of egress gateway")
    parser.add_argument("--agents-dir", default="agentic-lens/agents",
                        help="Path relative to cwd containing agent subdirectories")
    parser.add_argument("--out-dir", default="/tmp/engine_ids",
                        help="Directory to write <agent>.engine_id files")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    # Discover agents from subdirectories
    agents = []
    for d in sorted(glob.glob(os.path.join(args.agents_dir, "*/"))):
        name = os.path.basename(d.rstrip("/"))
        if "_staged" not in name:
            agents.append(name)

    if not agents:
        print(f"No agents found in {args.agents_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(agents)} agents: {', '.join(agents)}")
    print(f"Project: {args.project}  Location: {args.location}")
    print(f"Ingress:  {args.ingress}")
    print(f"Egress:   {args.egress}")
    print()

    if args.dry_run:
        print("DRY RUN — no changes will be made")
        return

    token = get_access_token()

    # List existing engines
    print("Fetching existing engines...")
    try:
        existing = list_engines(args.project, args.location, token)
        print(f"  Found {len(existing)} existing engines: {list(existing.keys())}")
    except Exception as e:
        print(f"  WARNING: Could not list engines: {e}", file=sys.stderr)
        existing = {}

    created = []
    skipped = []
    failed = []

    for agent in agents:
        print(f"\n[{agent}]")
        if agent in existing:
            engine = existing[agent]
            engine_name = engine.get("name", "")
            engine_id = extract_engine_id_from_name(engine_name)
            state = engine.get("state", "?")
            print(f"  Already exists — state={state}  id={engine_id}")
            # Write engine ID for deploy.sh to consume
            id_file = os.path.join(args.out_dir, f"{agent}.engine_id")
            with open(id_file, "w") as f:
                f.write(engine_id)
            skipped.append(agent)
            continue

        # Create lightweight engine with gateway config
        print(f"  Creating lightweight engine with gateway config...")
        try:
            op = create_lightweight_engine(
                args.project, args.location, token,
                display_name=agent,
                ingress=args.ingress,
                egress=args.egress
            )
            op_name = op.get("name", "")
            print(f"  Operation: {op_name}")
            resource = wait_for_operation(
                args.project, args.location, token, op_name, timeout=300
            )
            resource_name = resource.get("name", op_name.replace("operations/", ""))
            engine_id = extract_engine_id_from_name(resource_name)
            print(f"  ✅ Created: id={engine_id}  name={resource_name}")
            # Write engine ID
            id_file = os.path.join(args.out_dir, f"{agent}.engine_id")
            with open(id_file, "w") as f:
                f.write(engine_id)
            created.append(agent)
        except Exception as e:
            print(f"  ❌ Failed: {e}", file=sys.stderr)
            failed.append(agent)

    print()
    print(f"=== Summary ===")
    print(f"Created: {len(created)}  {created}")
    print(f"Skipped (existed): {len(skipped)}")
    print(f"Failed:  {len(failed)}  {failed}")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
