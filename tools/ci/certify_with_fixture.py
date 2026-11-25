"""Run credential-free local certification or docker smoke against a local HTTP LLM fixture.

The fixture endpoint is injected ONLY into a temporary certification copy or
SMOKE_EXTRA_ENV and NEVER written into coworld_manifest_template.json or the
published dist/coworld_manifest.json.
"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def docker_host_address() -> str:
    if sys.platform == "darwin":
        return "host.docker.internal"
    try:
        out = subprocess.check_output(
            [
                "docker",
                "network",
                "inspect",
                "bridge",
                "--format",
                "{{(index .IPAM.Config 0).Gateway}}",
            ],
            text=True,
        ).strip()
        if out:
            return out
    except Exception:
        pass
    return "172.17.0.1"


def start_fixture_server() -> tuple[ThreadingHTTPServer, list[dict[str, object]]]:
    calls: list[dict[str, object]] = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            length = int(self.headers.get("content-length", "0"))
            request = json.loads(self.rfile.read(length))
            if self.path != "/v1/messages":
                self.send_response(404)
                self.end_headers()
                return
            user_text = request["messages"][0]["content"]
            is_hider = '"crates":' in user_text and '"lit":' not in user_text
            order = (
                {
                    "intent": "hide",
                    "target": [240, 329],
                    "crawl": True,
                    "note": "ci-fixture",
                }
                if is_hider
                else {
                    "intent": "sweep",
                    "target": [240, 329],
                    "aim": "sweep",
                    "crawl": False,
                    "note": "ci-fixture",
                }
            )
            with lock:
                calls.append(
                    {
                        "model": request.get("model"),
                        "slot": self.headers.get("X-Coworld-Player-Slot"),
                    }
                )
                call_index = len(calls)
            text = json.dumps(order)
            if call_index == 1:
                text = f"```json\n{text}\n```"
            response = {
                "model": request.get("model") or "fixture/served",
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn",
            }
            payload = json.dumps(response).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_args: object) -> None:
            pass

    server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, calls


def assert_published_manifest_clean(manifest_path: Path) -> tuple[dict, set[str]]:
    manifest = json.loads(manifest_path.read_text())
    expected_models: set[str] = set()
    for player in manifest.get("player") or []:
        env = player.get("env") or {}
        if "COWORLD_LLM_ENDPOINT" in env:
            raise SystemExit(
                f"published manifest {manifest_path} MUST NOT contain COWORLD_LLM_ENDPOINT "
                f"(found on player {player.get('id')!r})"
            )
        if env.get("COWORLD_LLM_ENABLED") == "true":
            model = env.get("COWORLD_LLM_MODEL") or ""
            if not model:
                raise SystemExit(
                    f"model player {player.get('id')!r} is missing COWORLD_LLM_MODEL"
                )
            expected_models.add(model)
    if not expected_models:
        raise SystemExit(
            f"manifest {manifest_path} has no COWORLD_LLM_ENABLED=true player"
        )
    return manifest, expected_models


def run_certify(args: list[str]) -> int:
    if "--" not in args:
        raise SystemExit(
            "usage: certify_with_fixture.py certify <manifest> -- <cmd with {manifest}>"
        )
    sep = args.index("--")
    if sep != 1 or sep + 1 >= len(args):
        raise SystemExit(
            "usage: certify_with_fixture.py certify <manifest> -- <cmd with {manifest}>"
        )
    manifest_path = Path(args[0]).resolve()
    cmd_template = args[sep + 1 :]
    manifest, expected_models = assert_published_manifest_clean(manifest_path)

    server, calls = start_fixture_server()
    host = docker_host_address()
    endpoint = f"http://{host}:{server.server_port}"
    temp_manifest = manifest_path.parent / f".certify_fixture_{os.getpid()}.json"
    try:
        patched = copy.deepcopy(manifest)
        for player in patched.get("player") or []:
            env = player.setdefault("env", {})
            if env.get("COWORLD_LLM_ENABLED") == "true":
                env["COWORLD_LLM_ENDPOINT"] = endpoint
        temp_manifest.write_text(json.dumps(patched, indent=2) + "\n")
        cmd = [str(temp_manifest) if token == "{manifest}" else token for token in cmd_template]
        proc = subprocess.run(cmd)
        rc = proc.returncode
    finally:
        server.shutdown()
        if temp_manifest.exists():
            temp_manifest.unlink()

    assert_published_manifest_clean(manifest_path)
    if rc != 0:
        return rc
    if not calls:
        raise SystemExit("local HTTP fixture received 0 model calls during certification")
    seen_models = {c["model"] for c in calls}
    if not seen_models.issubset(expected_models):
        raise SystemExit(
            f"unexpected model(s) requested: {seen_models!r}, expected subset of {expected_models!r}"
        )
    print(
        f"local certification HTTP fixture OK: calls={len(calls)} models={sorted(seen_models)}",
        flush=True,
    )
    return 0


def run_docker_smoke(args: list[str]) -> int:
    if len(args) < 2:
        raise SystemExit("usage: certify_with_fixture.py docker-smoke <script> <image>")
    script, image = args[0], args[1]
    manifest_path = Path(os.environ.get("SMOKE_MANIFEST", "coworld_manifest_template.json")).resolve()
    _, expected_models = assert_published_manifest_clean(manifest_path)

    server, calls = start_fixture_server()
    host = docker_host_address()
    endpoint = f"http://{host}:{server.server_port}"
    env = dict(os.environ)
    existing = env.get("SMOKE_EXTRA_ENV", "").strip()
    extra = f"COWORLD_LLM_ENDPOINT={endpoint}"
    env["SMOKE_EXTRA_ENV"] = f"{existing} {extra}".strip()
    try:
        proc = subprocess.run([script, image], env=env)
        rc = proc.returncode
    finally:
        server.shutdown()

    if rc != 0:
        return rc
    if not calls:
        raise SystemExit("local HTTP fixture received 0 model calls during docker smoke")
    seen_models = {c["model"] for c in calls}
    if not seen_models.issubset(expected_models):
        raise SystemExit(
            f"unexpected model(s) requested: {seen_models!r}, expected subset of {expected_models!r}"
        )
    print(
        f"docker smoke HTTP fixture OK: calls={len(calls)} models={sorted(seen_models)}",
        flush=True,
    )
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: certify_with_fixture.py <certify|docker-smoke> ...")
    mode = sys.argv[1]
    if mode == "certify":
        return run_certify(sys.argv[2:])
    if mode == "docker-smoke":
        return run_docker_smoke(sys.argv[2:])
    raise SystemExit(f"unknown mode: {mode!r}")


if __name__ == "__main__":
    raise SystemExit(main())
