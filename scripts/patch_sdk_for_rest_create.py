#!/usr/bin/env python3
"""
patch_sdk_for_rest_create.py  (v2 — pth-file approach)

Injects a startup hook into the venv so that EVERY Python process
(including 'adk' subprocess calls from deploy.sh) monkey-patches
VertexAiReasoningEngineServiceClient.create_reasoning_engine to use
the REST API and include all 3 org policy required fields:

  1. spec.identityType = "AGENT_IDENTITY"
  2. spec.deploymentSpec.agentGatewayConfig.{clientToAgentConfig,agentToAnywhereConfig}
  3. spec.deploymentSpec.env with 3 OTEL vars

Method: writes _gateway_patch.py + _gateway_patch.pth into venv site-packages.
Python auto-processes .pth files containing 'import ...' lines at startup,
which monkey-patches the gRPC client class before any SDK code runs.
"""
import argparse
import glob
import os
import sys


PATCH_MODULE = "_gateway_patch"


def find_site_packages(venv_dir: str) -> str:
    matches = glob.glob(
        os.path.join(venv_dir, "lib", "python*", "site-packages")
    )
    if not matches:
        raise FileNotFoundError(
            f"Cannot find site-packages in venv: {venv_dir}"
        )
    return sorted(matches)[-1]


PATCH_PY = '''\
"""
_gateway_patch.py — auto-imported via _gateway_patch.pth

Monkey-patches VertexAiReasoningEngineServiceClient.create_reasoning_engine
so that every gRPC CREATE call is redirected to a REST API call that includes
spec.deploymentSpec.agentGatewayConfig (required by org policy).
"""
import os as _os
import json as _json
import urllib.request as _urllib
import urllib.error

_INGRESS = _os.environ.get("AGENT_GATEWAY_INGRESS", "")
_EGRESS  = _os.environ.get("AGENT_GATEWAY_EGRESS", "")
_OTEL_VARS = [
    ("GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY",           "true"),
    ("OTEL_SEMCONV_STABILITY_OPT_IN",                        "gen_ai_latest_experimental"),
    ("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT",   "EVENT_ONLY"),
]


def _rest_create(original_self, request=None, *, parent=None, reasoning_engine=None,
                 retry=None, timeout=None, metadata=None, **kw):
    """REST replacement for gRPC create_reasoning_engine."""
    import google.auth as _ga
    import google.auth.transport.requests as _gatr
    from google.protobuf import json_format as _jf

    # Normalise args (gRPC uses a request wrapper OR keyword args)
    if request is not None and hasattr(request, "reasoning_engine"):
        _re  = request.reasoning_engine
        _par = request.parent
    else:
        _re  = reasoning_engine
        _par = parent

    # proto → dict (camelCase for REST)
    re_dict = _jf.MessageToDict(_re._pb, preserving_proto_field_name=False)

    # Inject org-policy mandatory fields
    spec = re_dict.setdefault("spec", {})
    spec["identityType"] = "AGENT_IDENTITY"

    ds  = spec.setdefault("deploymentSpec", {})
    ds["agentGatewayConfig"] = {
        "clientToAgentConfig":  {"agentGateway": _INGRESS},
        "agentToAnywhereConfig": {"agentGateway": _EGRESS},
    }
    env  = ds.setdefault("env", [])
    have = {e.get("name") for e in env}
    for k, v in _OTEL_VARS:
        if k not in have:
            env.append({"name": k, "value": v})

    # Parse project + location from parent path
    parts   = (_par or "").split("/")
    project = parts[1] if len(parts) > 1 else ""
    loc     = parts[3] if len(parts) > 3 else "us-central1"
    url = (f"https://{loc}-aiplatform.googleapis.com/v1beta1/"
           f"projects/{project}/locations/{loc}/reasoningEngines")

    creds, _ = _ga.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
    creds.refresh(_gatr.Request())

    body = _json.dumps(re_dict).encode()
    req  = _urllib.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {creds.token}",
        "Content-Type":  "application/json",
    })
    display = re_dict.get("displayName", "?")
    print(f"[gateway_patch] REST CREATE → {display}", flush=True)
    try:
        with _urllib.urlopen(req, timeout=120) as resp:
            op_data = _json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        err = exc.read().decode(errors="replace")
        raise RuntimeError(f"[gateway_patch] REST failed {exc.code}: {err}") from exc

    op_name = op_data.get("name", "")
    print(f"[gateway_patch] LRO → {op_name}", flush=True)
    return _GwFuture(op_name, creds, loc, project)


class _GwFuture:
    """Polls the REST LRO and returns a proto-compatible result."""

    def __init__(self, op_name, creds, location, project):
        self._op   = op_name
        self._cred = creds
        self._loc  = location
        self._proj = project

    # SDK calls .result() to wait for the operation
    def result(self, timeout=900):
        import time
        import google.auth.transport.requests as _gatr
        from google.cloud.aiplatform_v1beta1.types import reasoning_engine as _aip
        from google.protobuf import json_format as _jf

        deadline = time.time() + timeout
        while time.time() < deadline:
            self._cred.refresh(_gatr.Request())
            url = (f"https://{self._loc}-aiplatform.googleapis.com/v1/"
                   f"{self._op}")
            req = _urllib.Request(url, headers={"Authorization": f"Bearer {self._cred.token}"})
            with _urllib.urlopen(req, timeout=30) as resp:
                op = _json.loads(resp.read())
            if op.get("done"):
                if "error" in op:
                    raise RuntimeError(f"[gateway_patch] LRO error: {op[\'error\']}")
                raw = op.get("response", {})
                # Convert JSON → proto
                try:
                    pb  = _jf.ParseDict(raw, _aip.ReasoningEngine()._pb,
                                        ignore_unknown_fields=True)
                    res = _aip.ReasoningEngine(pb)
                except Exception:
                    # Fallback minimal stub
                    class _Stub:
                        name         = raw.get("name", "")
                        display_name = raw.get("displayName", "")
                    res = _Stub()
                print(f"[gateway_patch] DONE → {getattr(res, \'name\', \'?\')}",
                      flush=True)
                return res
            time.sleep(15)
        raise TimeoutError(f"[gateway_patch] LRO timed out: {self._op}")

    # SDK may also call these on the future object
    def add_done_callback(self, fn): pass
    def cancelled(self): return False
    def running(self): return True


def _apply():
    if not _INGRESS or not _EGRESS:
        print("[gateway_patch] No AGENT_GATEWAY_INGRESS/EGRESS — skipping.", flush=True)
        return
    try:
        from google.cloud.aiplatform_v1beta1.services.vertex_ai_reasoning_engine_service \\
            import VertexAiReasoningEngineServiceClient as _Cls
        _Cls.create_reasoning_engine = _rest_create
        print("[gateway_patch] Patched VertexAiReasoningEngineServiceClient.create_reasoning_engine",
              flush=True)
    except Exception as exc:
        print(f"[gateway_patch] Patch failed: {exc}", flush=True)


_apply()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingress", required=True)
    parser.add_argument("--egress",  required=True)
    parser.add_argument("--venv",    default=".venv")
    args = parser.parse_args()

    try:
        sp = find_site_packages(args.venv)
    except FileNotFoundError as exc:
        print(f"[patch] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    # 1. Write _gateway_patch.py (the actual monkey-patch code)
    patch_py = os.path.join(sp, f"{PATCH_MODULE}.py")
    with open(patch_py, "w") as f:
        f.write(PATCH_PY)
    print(f"[patch] Wrote {patch_py}")

    # 2. Write _gateway_patch.pth  (Python auto-imports this at startup)
    patch_pth = os.path.join(sp, f"{PATCH_MODULE}.pth")
    with open(patch_pth, "w") as f:
        f.write(f"import {PATCH_MODULE}\n")
    print(f"[patch] Wrote {patch_pth}")

    # 3. Set env vars so _gateway_patch.py can read them at import time
    #    (These env vars must also be set in the Cloud Build step env)
    print(f"[patch] ingress: {args.ingress}")
    print(f"[patch] egress:  {args.egress}")
    print(f"[patch] IMPORTANT: ensure AGENT_GATEWAY_INGRESS and AGENT_GATEWAY_EGRESS")
    print(f"[patch]            are exported in the shell before running deploy.sh")

    # 4. Verify the patch loads cleanly in this Python
    print("[patch] Verifying patch loads...")
    import importlib.util, subprocess
    result = subprocess.run(
        [sys.executable, "-c",
         f"import sys; sys.path.insert(0, {sp!r}); "
         f"import os; os.environ['AGENT_GATEWAY_INGRESS']={args.ingress!r}; "
         f"os.environ['AGENT_GATEWAY_EGRESS']={args.egress!r}; "
         f"import {PATCH_MODULE}; print('verify OK')"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"[patch] Verify FAILED:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    print(f"[patch] {result.stdout.strip()}")
    print("[patch] Done ✅")


if __name__ == "__main__":
    main()
