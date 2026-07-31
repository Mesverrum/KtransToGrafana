#!/usr/bin/env python3
"""Push v2 ktranslate dashboards from dashboards/ to Grafana Cloud (v2 API).

Requires GRAFANA_URL and GRAFANA_TOKEN in the environment (or .env in repo root).
Optional:
  GRAFANA_DASHBOARD_NAMESPACE  default stacks-<GC_OTLP_ACCOUNT>
  GRAFANA_DASHBOARD_FOLDER     default network-lab
  KTRANS_PUSH_SKIP             comma-separated filenames to skip (e.g. flow board)

Usage:
  python3 scripts/push-dashboards.py
  python3 scripts/push-dashboards.py --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DASH_DIR = REPO / "dashboards"
DEFAULT_SKIP = {"02 Network Flow Summary.json"}


def load_env() -> None:
    env_file = REPO / ".env"
    if not env_file.is_file():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.strip().startswith("#"):
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def namespace() -> str:
    ns = os.environ.get("GRAFANA_DASHBOARD_NAMESPACE", "").strip()
    if ns:
        return ns
    account = os.environ.get("GC_OTLP_ACCOUNT", "").strip()
    if not account:
        sys.exit("set GRAFANA_DASHBOARD_NAMESPACE or GC_OTLP_ACCOUNT")
    return f"stacks-{account}"


def req(method: str, base: str, token: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        base + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            payload = json.loads(raw)
        except Exception:
            payload = {"raw": raw[:2000]}
        return e.code, payload


def upsert(
    dash: dict,
    *,
    base: str,
    token: str,
    ns: str,
    folder: str,
    dry_run: bool,
) -> tuple[str, int, str]:
    name = dash["metadata"]["name"]
    title = (dash.get("spec") or {}).get("title", name)
    if dry_run:
        return title, 200, "dry-run"

    ann = dash.setdefault("metadata", {}).setdefault("annotations", {})
    ann["grafana.app/folder"] = ann.get("grafana.app/folder", folder)
    for key in ("resourceVersion", "generation", "creationTimestamp", "uid"):
        dash["metadata"].pop(key, None)

    get_path = f"/apis/dashboard.grafana.app/v2/namespaces/{ns}/dashboards/{name}"
    status, existing = req("GET", base, token, get_path)
    if status == 200:
        rv = (existing.get("metadata") or {}).get("resourceVersion")
        if rv:
            dash["metadata"]["resourceVersion"] = rv
        status, _out = req("PUT", base, token, get_path, dash)
        return title, status, "updated"

    create_path = f"/apis/dashboard.grafana.app/v2/namespaces/{ns}/dashboards"
    status, _out = req("POST", base, token, create_path, dash)
    if status in (409, 403):
        status, _out = req("PUT", base, token, get_path, dash)
        return title, status, "updated"
    return title, status, "created"


def skip_set() -> set[str]:
    raw = os.environ.get("KTRANS_PUSH_SKIP", "").strip()
    skipped = set(DEFAULT_SKIP)
    if raw:
        skipped.update(part.strip() for part in raw.split(",") if part.strip())
    return skipped


def main() -> int:
    parser = argparse.ArgumentParser(description="Push dashboards/ to Grafana Cloud v2 API")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    load_env()
    base = os.environ.get("GRAFANA_URL", "").rstrip("/")
    token = os.environ.get("GRAFANA_TOKEN", "")
    if not base or not token:
        sys.exit("set GRAFANA_URL and GRAFANA_TOKEN in .env or environment")

    ns = namespace()
    folder = os.environ.get("GRAFANA_DASHBOARD_FOLDER", "network-lab").strip() or "network-lab"
    skipped = skip_set()
    fails = 0

    for path in sorted(DASH_DIR.glob("*.json")):
        if path.name in skipped:
            print(f"skip {path.name}")
            continue
        dash = json.loads(path.read_text(encoding="utf-8"))
        title, status, action = upsert(
            dash,
            base=base,
            token=token,
            ns=ns,
            folder=folder,
            dry_run=args.dry_run,
        )
        ok = 200 <= status < 300
        print(f"{'OK' if ok else 'FAIL'} {path.name} ({title}) {action} http={status}")
        if not ok:
            fails += 1

    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
