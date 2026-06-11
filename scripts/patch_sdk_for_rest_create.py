#!/usr/bin/env python3
"""
patch_sdk_for_rest_create.py  (v3 — correct client class)

Injects a startup hook into the venv so that EVERY Python process
(including 'adk' subprocess calls from deploy.sh) monkey-patches
ReasoningEngineClientWithOverride.create_reasoning_engine to use
the REST API and include all 3 org policy required fields:

  1. spec.identityType = "AGENT_IDENTITY"
  2. spec.deploymentSpec.agentGatewayConfig.{clientToAgentConfig,agentToAnywhereConfig}
  3. spec.deploymentSpec.env with 3 OTEL vars

Method: writes _gateway_patch.py + _gateway_patch.pth into the ADK venv's
site-packages (agentic-lens/.venv). Python auto-processes .pth files containing
'import ...' lines at startup — so the monkey-patch applies before any SDK code
runs, for ALL Python subprocesses.

IMPORTANT: All output from _gateway_patch.py goes to STDERR so it does NOT
pollute stdout captures like:  existing_id=$(python get_agent_engine_id.py ...)
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
            f"Cannot find site-packages in venv: {venv_dir!r}"
        )
    return sorted(matches)[-1]


# --------------------------------------------------------------------------
# The code that will be written into <site-packages>/_gateway_patch.py
# ALL print() calls use file=_sys.stderr to avoid stdout pollution.
# --------------------------------------------------------------------------
PATCH_PY = r'''
"""
_gateway_patch.py — auto-imported via _gateway_patch.pth at Python startup.

Monkey-patches ReasoningEngineClientWithOverride.create_reasoning_engine
so every gRPC CREATE call is redirected to a REST v1beta1 API call that
includes the 3 org-policy-required fields.

ALL output goes to STDERR — never stdout — to prevent pollution of
  existing_id=$(agentic-lens/.venv/bin/python get_agent_engine_id.py ...)
"""
import os as _os
import sys as _sys
import json as _json
import urllib.request as _urllib
import urllib.error as _urlerr

_INGRESS = _os.environ.get("AGENT_GATEWAY_INGRESS", "")
_EGRESS  = _os.environ.get("AGENT_GATEWAY_EGRESS", "")
_OTEL_VARS = [
    ("GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY",         "true"),
    ("OTEL_SEMCONV_STABILITY_OPT_IN",                      "gen_ai_latest_experimental"),
    ("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "EVENT_ONLY"),
]


def _rest_create(original_self, request=None, *, parent=None,
                 reasoning_engine=None, retry=None, timeout=None,
                 metadata=None, **kw):
    """REST replacement for gRPC create_reasoning_engine."""
    import google.auth as _ga
    import google.auth.transport.requests as _gatr
    from google.protobuf import json_format as _jf

    # Normalise args: gRPC client accepts a request wrapper OR keyword args
    if request is not None and hasattr(request, "reasoning_engine"):
        _re  = request.reasoning_engine
        _par = request.parent
    else:
        _re  = reasoning_engine
        _par = parent

    # proto -> dict (camelCase for REST)
    re_dict = _jf.MessageToDict(_re._pb, preserving_proto_field_name=False)

    # Inject org-policy mandatory fields
    spec = re_dict.setdefault("spec", {})
    spec["identityType"] = "AGENT_IDENTITY"

    ds = spec.setdefault("deploymentSpec", {})
    ds["agentGatewayConfig"] = {
        "clientToAgentConfig":   {"agentGateway": _INGRESS},
        "agentToAnywhereConfig": {"agentGateway": _EGRESS},
    }
    env   = ds.setdefault("env", [])
    have  = {e.get("name") for e in env}
    for k, v in _OTEL_VARS:
        if k not in have:
            env.append({"name": k, "value": v})

    # Parse project + location from parent path
    parts   = (_par or "").split("/")
    project = parts[1] if len(parts) > 1 else ""
    loc     = parts[3] if len(parts) > 3 else "us-central1"
    url = (f"https://{loc}-aiplatform.googleapis.com/v1beta1/"
           f"projects/{project}/locations/{loc}/reasoningEngines")

    creds, _ = _ga.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(_gatr.Request())

    body = _json.dumps(re_dict).encode()
    req  = _urllib.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {creds.token}",
        "Content-Type":  "application/json",
    })
    display = re_dict.get("displayName", "?")
    print(f"[gateway_patch] REST CREATE -> {display}", file=_sys.stderr, flush=True)
    try:
        with _urllib.urlopen(req, timeout=120) as resp:
            op_data = _json.loads(resp.read())
    except _urlerr.HTTPError as exc:
        err = exc.read().decode(errors="replace")
        raise RuntimeError(f"[gateway_patch] REST failed {exc.code}: {err}") from exc

    op_name = op_data.get("name", "")
    print(f"[gateway_patch] LRO -> {op_name}", file=_sys.stderr, flush=True)
    return _GwFuture(op_name, creds, loc, project)


class _GwFuture:
    """Polls the REST LRO and returns a name-compatible stub."""

    def __init__(self, op_name, creds, location, project):
        self._op   = op_name
        self._cred = creds
        self._loc  = location
        self._proj = project

    def result(self, timeout=900):
        import time
        import google.auth.transport.requests as _gatr

        deadline = time.time() + timeout
        while time.time() < deadline:
            self._cred.refresh(_gatr.Request())
            url = (f"https://{self._loc}-aiplatform.googleapis.com/v1/"
                   f"{self._op}")
            req = _urllib.Request(
                url, headers={"Authorization": f"Bearer {self._cred.token}"}
            )
            with _urllib.urlopen(req, timeout=30) as resp:
                op = _json.loads(resp.read())
            if op.get("done"):
                if "error" in op:
                    raise RuntimeError(
                        f"[gateway_patch] LRO error: {op['error']}"
                    )
                raw = op.get("response", {})
                # Return a lightweight stub — ADK only needs .name / .display_name
                class _Stub:
                    name         = raw.get("name", "")
                    display_name = raw.get("displayName", "")
                res = _Stub()
                print(f"[gateway_patch] DONE -> {res.name}",
                      file=_sys.stderr, flush=True)
                return res
            time.sleep(15)
        raise TimeoutError(f"[gateway_patch] LRO timed out: {self._op}")

    def add_done_callback(self, fn): pass
    def cancelled(self): return False
    def running(self): return True


def _apply():
    if not _INGRESS or not _EGRESS:
        print("[gateway_patch] No AGENT_GATEWAY_INGRESS/EGRESS — skipping.",
              file=_sys.stderr, flush=True)
        return

    # ------------------------------------------------------------------ #
    # PRIMARY: Transport-level HTTP interception                           #
    # google-cloud-aiplatform REST transport uses AuthorizedSession for    #
    # ALL HTTP calls.  Patching at this layer catches every               #
    # CreateReasoningEngine call regardless of inner class structure.      #
    # ------------------------------------------------------------------ #
    def _inject_gateway(body, url):
        """Inject org-policy fields into a CreateReasoningEngine body."""
        spec = body.setdefault("spec", {})
        spec["identityType"] = "AGENT_IDENTITY"
        ds = spec.setdefault("deploymentSpec", {})
        ds["agentGatewayConfig"] = {
            "clientToAgentConfig":   {"agentGateway": _INGRESS},
            "agentToAnywhereConfig": {"agentGateway": _EGRESS},
        }
        env  = ds.setdefault("env", [])
        have = {e.get("name") for e in env}
        for k, v in _OTEL_VARS:
            if k not in have:
                env.append({"name": k, "value": v})
        print(f"[gateway_patch] Injected gateway config into POST {url}",
              file=_sys.stderr, flush=True)
        return body

    def _is_create_reasoning_engine(method, url):
        """True if this is a CreateReasoningEngine REST call."""
        return (
            method.upper() == "POST"
            and "reasoningEngines" in url
            # exclude list/get (those end with resourceId or have ?)
            and not url.rstrip("/").endswith("reasoningEngines") is False
            and "?" not in url.split("reasoningEngines")[-1]
            and not url.split("reasoningEngines")[-1].strip("/").isdigit()
        )

    # Simpler predicate: POST to a URL containing /reasoningEngines
    # that does NOT have a resource-ID suffix or query params
    def _is_create_re(method, url):
        url_str = str(url)
        if method.upper() != "POST":
            return False
        if "reasoningEngines" not in url_str:
            return False
        suffix = url_str.split("reasoningEngines", 1)[-1]
        # Create: suffix is empty or just "/"
        # Update: suffix is "/<id>" or "/<id>?..."
        # List:   suffix is "" with GET
        suffix = suffix.lstrip("/").split("?")[0]
        # If suffix is a numeric ID → this is an UpdateReasoningEngine call
        # We still want to inject gateway config on updates too
        return True  # inject on ALL POST to reasoningEngines

    try:
        from google.auth.transport.requests import AuthorizedSession as _ASession
        _orig_send = _ASession.send

        def _patched_send(self, request, **kwargs):
            # `request` is a PreparedRequest — .body and .headers are FINAL here.
            # Patching send() is the only guaranteed place where Content-Length
            # is already computed from the original body and can be corrected
            # after we inject our extra fields.
            url_str = str(request.url)
            if (request.method.upper() == "POST" and
                    "reasoningEngines" in url_str):
                try:
                    raw_body = request.body
                    if isinstance(raw_body, bytes):
                        body = _json.loads(raw_body)
                    elif isinstance(raw_body, str):
                        body = _json.loads(raw_body)
                    else:
                        body = None

                    if body is not None:
                        body = _inject_gateway(body, url_str)
                        encoded = _json.dumps(body).encode()
                        # Mutate the PreparedRequest in-place
                        request.body = encoded
                        # Delete Content-Length entirely — urllib3 will
                        # recompute it from len(body) before sending.
                        # This avoids any case-sensitivity / timing race
                        # with http.client's Content-Length check.
                        request.headers.pop("Content-Length", None)
                        request.headers.pop("content-length", None)
                        request.headers["Content-Type"] = "application/json"
                        print(
                            f"[gateway_patch] body={len(encoded)}B "
                            f"cl_after={request.headers.get('Content-Length','(removed)')}",
                            file=_sys.stderr, flush=True)
                except Exception as exc:
                    print(f"[gateway_patch] send() injection failed: {exc}",
                          file=_sys.stderr, flush=True)
            return _orig_send(self, request, **kwargs)

        _ASession.send = _patched_send
        print("[gateway_patch] Patched AuthorizedSession.send (PreparedRequest level)",
              file=_sys.stderr, flush=True)
    except Exception as exc:
        print(f"[gateway_patch] AuthorizedSession patch failed: {exc}",
              file=_sys.stderr, flush=True)

    # ------------------------------------------------------------------ #
    # SECONDARY: Also try to patch httpx (used by some SDK versions)      #
    # ------------------------------------------------------------------ #
    try:
        import httpx as _httpx
        _orig_httpx_send = _httpx.Client.send

        def _patched_httpx_send(self, request, **kwargs):
            url_str = str(request.url)
            if (request.method.upper() == "POST" and
                    "reasoningEngines" in url_str):
                try:
                    body = _json.loads(request.content)
                    body = _inject_gateway(body, url_str)
                    encoded = _json.dumps(body).encode()
                    # Rebuild request with new body
                    request = _httpx.Request(
                        method=request.method,
                        url=request.url,
                        headers=dict(request.headers),
                        content=encoded,
                    )
                except Exception as e:
                    print(f"[gateway_patch] httpx body injection failed: {e}",
                          file=_sys.stderr, flush=True)
            return _orig_httpx_send(self, request, **kwargs)

        _httpx.Client.send = _patched_httpx_send
        print("[gateway_patch] Patched httpx.Client.send (transport level)",
              file=_sys.stderr, flush=True)
    except Exception as exc:
        print(f"[gateway_patch] httpx patch skipped: {exc}",
              file=_sys.stderr, flush=True)

    # ------------------------------------------------------------------ #
    # BELT-AND-SUSPENDERS: patch known GAPIC client classes directly      #
    # ------------------------------------------------------------------ #
    for module_path, class_name in [
        ("google.cloud.aiplatform_v1beta1.services.reasoning_engine_service.client",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform_v1beta1.services.reasoning_engine_service",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform_v1.services.reasoning_engine_service.client",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform_v1.services.reasoning_engine_service",
         "ReasoningEngineServiceClient"),
        ("google.cloud.aiplatform.utils",
         "ReasoningEngineClientWithOverride"),
    ]:
        try:
            import importlib
            mod = importlib.import_module(module_path)
            cls = getattr(mod, class_name)
            cls.create_reasoning_engine = _rest_create
            print(f"[gateway_patch] Patched {class_name} (class level)",
                  file=_sys.stderr, flush=True)
        except Exception as e:
            print(f"[gateway_patch] Skip {class_name}: {e}",
                  file=_sys.stderr, flush=True)


_apply()

'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ingress", required=True)
    parser.add_argument("--egress",  required=True)
    parser.add_argument("--venv",    default="agentic-lens/.venv",
                        help="Path to the ADK venv (default: agentic-lens/.venv)")
    args = parser.parse_args()

    try:
        sp = find_site_packages(args.venv)
    except FileNotFoundError as exc:
        print(f"[patch] ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"[patch] Target venv site-packages: {sp}")

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

    print(f"[patch] ingress: {args.ingress}")
    print(f"[patch] egress:  {args.egress}")
    print("[patch] IMPORTANT: AGENT_GATEWAY_INGRESS and AGENT_GATEWAY_EGRESS")
    print("[patch]            must be exported in the shell before deploy.sh runs")

    # 3. Verify the patch can be imported and applies cleanly
    print("[patch] Verifying patch loads in target Python...")
    import subprocess

    # Find the Python in the target venv
    target_python = os.path.join(args.venv, "bin", "python")
    if not os.path.isfile(target_python):
        target_python = sys.executable
        print(f"[patch] WARNING: {args.venv}/bin/python not found, using {target_python}")

    result = subprocess.run(
        [target_python, "-c",
         f"import sys; sys.path.insert(0, {sp!r}); "
         f"import os; os.environ['AGENT_GATEWAY_INGRESS']={args.ingress!r}; "
         f"os.environ['AGENT_GATEWAY_EGRESS']={args.egress!r}; "
         f"import {PATCH_MODULE}; print('verify OK')"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"[patch] Verify FAILED:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    # Print stderr from the verification (the [gateway_patch] messages)
    if result.stderr:
        for line in result.stderr.strip().splitlines():
            print(f"[patch]  {line}")
    out = result.stdout.strip()
    if out:
        print(f"[patch] {out}")
    print("[patch] Done ✅")


if __name__ == "__main__":
    main()
