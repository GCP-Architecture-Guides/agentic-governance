#!/usr/bin/env python3
"""
patch_sdk_for_rest_create.py

Modifies the vertexai SDK's _agent_engines.py in the venv so that
`create_reasoning_engine` calls are redirected to the REST API. This allows
injecting `spec.deploymentSpec.agentGatewayConfig` which is required by:

  customConstraints/custom.enforceReasoningEngineAgentGatewayConfig
    → spec.deploymentSpec.agentGatewayConfig.{clientToAgentConfig,agentToAnywhereConfig}

  customConstraints/custom.enforceReasoningEngineOtelConfig
    → spec.deploymentSpec.env must contain 3 specific OTEL vars

  customConstraints/custom.enforceAgentIdentityForReasoningEngine
    → spec.identityType = "AGENT_IDENTITY"

The gRPC proto's DeploymentSpec does NOT have agentGatewayConfig, so the
standard ADK path always violates these policies. This patch converts the
proto to a JSON dict, injects the required fields, then makes a REST POST.

Usage (add to cloudbuild.yaml BEFORE deploy.sh):
  python3 /workspace/scripts/patch_sdk_for_rest_create.py \\
      --ingress "projects/.../agentGateways/gemini-corp-ingress-gateway" \\
      --egress  "projects/.../agentGateways/gemini-corp-egress-gateway"
"""
import argparse
import glob
import os
import sys
import textwrap


PATCH_MARKER = "# __GATEWAY_PATCH_APPLIED__"

PATCH_TEMPLATE = textwrap.dedent('''\
# {marker}
# Injected by patch_sdk_for_rest_create.py to satisfy org-policy gateway constraints.
import os as _gw_os, json as _gw_json, urllib.request as _gw_urllib

_GW_INGRESS = {ingress!r}
_GW_EGRESS  = {egress!r}
_GW_OTEL = [
    {{"name": "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY",           "value": "true"}},
    {{"name": "OTEL_SEMCONV_STABILITY_OPT_IN",                        "value": "gen_ai_latest_experimental"}},
    {{"name": "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",   "value": "EVENT_ONLY"}},
]

def _gw_rest_create(api_client, parent, reasoning_engine):
    """Replace gRPC create_reasoning_engine with a REST call that adds gateway config."""
    from google.protobuf import json_format as _jf
    import google.auth as _ga
    import google.auth.transport.requests as _gatr

    # Serialize proto → dict
    re_dict = _jf.MessageToDict(reasoning_engine._pb, preserving_proto_field_name=False)

    # Inject spec.identityType
    spec = re_dict.setdefault("spec", {{}})
    spec["identityType"] = "AGENT_IDENTITY"

    # Inject spec.deploymentSpec.agentGatewayConfig
    ds = spec.setdefault("deploymentSpec", {{}})
    ds["agentGatewayConfig"] = {{
        "clientToAgentConfig":  {{"agentGateway": _GW_INGRESS}},
        "agentToAnywhereConfig": {{"agentGateway": _GW_EGRESS}},
    }}

    # Inject OTEL vars (add only if not already present)
    env = ds.setdefault("env", [])
    existing_names = {{e.get("name") for e in env}}
    for otel_var in _GW_OTEL:
        if otel_var["name"] not in existing_names:
            env.append(otel_var)

    # Build project / location from parent  ("projects/P/locations/L")
    parts = parent.split("/")
    project_id  = parts[1] if len(parts) > 1 else ""
    location    = parts[3] if len(parts) > 3 else "us-central1"
    url = (
        f"https://{{location}}-aiplatform.googleapis.com/v1beta1/"
        f"projects/{{project_id}}/locations/{{location}}/reasoningEngines"
    )

    # Authenticate
    creds, _ = _ga.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(_gatr.Request())

    body = _gw_json.dumps(re_dict).encode()
    req = _gw_urllib.Request(
        url, data=body,
        headers={{
            "Authorization": f"Bearer {{creds.token}}",
            "Content-Type": "application/json",
        }},
        method="POST",
    )
    print(f"[gateway_patch] REST CREATE for {{re_dict.get('displayName','?')}} ...", flush=True)
    try:
        with _gw_urllib.urlopen(req, timeout=120) as resp:
            op_data = _gw_json.loads(resp.read())
    except _gw_urllib.error.HTTPError as exc:
        body_txt = exc.read().decode(errors="replace")
        raise RuntimeError(f"REST CREATE failed {{exc.code}}: {{body_txt}}") from exc

    op_name = op_data.get("name", "")
    print(f"[gateway_patch] LRO started: {{op_name}}", flush=True)

    # Return a future-like object that polls the LRO
    return _GwOperationFuture(op_name, creds, location)


class _GwOperationFuture:
    """Minimal LRO poller compatible with the SDK's operation_future.result() call."""
    def __init__(self, op_name, creds, location):
        self._op_name = op_name
        self._creds   = creds
        self._location = location
        self._result  = None

    def result(self, timeout=600):
        import time, google.auth.transport.requests as _gatr
        deadline = time.time() + timeout
        while time.time() < deadline:
            self._creds.refresh(_gatr.Request())
            url = (
                f"https://{{self._location}}-aiplatform.googleapis.com/v1/"
                f"{{self._op_name}}"
            )
            req = _gw_urllib.Request(
                url,
                headers={{"Authorization": f"Bearer {{self._creds.token}}"}},
            )
            with _gw_urllib.urlopen(req, timeout=30) as resp:
                op = _gw_json.loads(resp.read())
            if op.get("done"):
                if "error" in op:
                    raise RuntimeError(f"LRO failed: {{op['error']}}")
                resp_proto = op.get("response", {{}})
                print(f"[gateway_patch] Engine ACTIVE: {{resp_proto.get('name','?')}}", flush=True)
                self._result = resp_proto
                return resp_proto
            time.sleep(15)
        raise TimeoutError(f"LRO {{self._op_name}} timed out after {{timeout}}s")

# END OF INJECTED PATCH
''')


TARGET_CALL = (
    "operation_future = sdk_resource.api_client.create_reasoning_engine("
)
REPLACEMENT_CALL = (
    "operation_future = _gw_rest_create("
    "sdk_resource.api_client, "
    "initializer.global_config.common_location_path("
    "project=sdk_resource.project, location=sdk_resource.location), "
    "reasoning_engine)"
)


def find_agent_engines_py(venv_dir: str = ".venv") -> str:
    matches = glob.glob(
        os.path.join(venv_dir, "lib", "python*", "site-packages",
                     "vertexai", "agent_engines", "_agent_engines.py")
    )
    if not matches:
        raise FileNotFoundError(
            f"Cannot find _agent_engines.py in {venv_dir}"
        )
    return sorted(matches)[-1]


def patch_file(path: str, ingress: str, egress: str) -> None:
    with open(path) as f:
        src = f.read()

    if PATCH_MARKER in src:
        print(f"[patch] Already patched: {path}")
        return

    if TARGET_CALL not in src:
        raise RuntimeError(
            f"Could not find target call in {path}:\n  {TARGET_CALL!r}"
        )

    # 1. Prepend the patch helper code at the top of the file (after the module docstring / imports)
    patch_code = PATCH_TEMPLATE.format(
        marker=PATCH_MARKER,
        ingress=ingress,
        egress=egress,
    )

    # Insert after the last top-level import block (find first non-import, non-comment line)
    lines = src.splitlines(keepends=True)
    insert_at = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("import ") or stripped.startswith("from ") or \
           stripped.startswith("#") or stripped == "" or stripped.startswith('"""') or \
           stripped.startswith("'''"):
            insert_at = i + 1
        else:
            break
    lines.insert(insert_at, patch_code + "\n")
    src = "".join(lines)

    # 2. Replace the gRPC call site with our REST wrapper
    src = src.replace(TARGET_CALL, REPLACEMENT_CALL, 1)

    # Remove the now-redundant parent= and reasoning_engine= keyword args that
    # followed the original call (they become positional in the wrapper).
    # The original call was:
    #   operation_future = sdk_resource.api_client.create_reasoning_engine(
    #       parent=initializer.global_config.common_location_path(
    #           project=sdk_resource.project, location=sdk_resource.location
    #       ),
    #       reasoning_engine=reasoning_engine,
    #   )
    # Our replacement is a single-line call, so strip the old args.
    import re
    src = re.sub(
        r'_gw_rest_create\([^)]*\)\s*\n(\s+parent=.*?\n\s+reasoning_engine=reasoning_engine,\n\s+\))',
        lambda m: '_gw_rest_create(' + m.group(0).split('(')[1].split(')')[0].strip().split('\n')[0] + ')',
        src,
        flags=re.DOTALL,
    )

    with open(path, "w") as f:
        f.write(src)

    print(f"[patch] Patched successfully: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingress", required=True,
                        help="Full resource name of ingress agent gateway")
    parser.add_argument("--egress", required=True,
                        help="Full resource name of egress agent gateway")
    parser.add_argument("--venv", default=".venv",
                        help="Path to the venv (default: .venv)")
    args = parser.parse_args()

    try:
        path = find_agent_engines_py(args.venv)
        print(f"[patch] Target: {path}")
        patch_file(path, args.ingress, args.egress)
    except Exception as exc:
        print(f"[patch] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
