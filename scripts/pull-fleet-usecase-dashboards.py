#!/usr/bin/env python3
"""Pull fleet use-case dashboards 05-10 from live Grafana into dashboards/."""
from __future__ import annotations

import json
import os
import ssl
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
UIDS = {
    "ktranslate-network-inventory": "05 Network Inventory.json",
    "ktranslate-network-risk": "06 Network Risk.json",
    "ktranslate-network-capacity": "07 Network Capacity.json",
    "ktranslate-network-events": "08 Network Events.json",
    "ktranslate-network-environment": "09 Network Environment.json",
    "ktranslate-network-adjacency": "10 Network Adjacency.json",
}


def load_env() -> None:
    for env_file in (
        REPO / ".env",
        REPO.parent / "network-o11y-demo" / "local" / ".env",
    ):
        if not env_file.is_file():
            continue
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def main() -> None:
    load_env()
    base = os.environ["GRAFANA_URL"].rstrip("/")
    token = os.environ["GRAFANA_TOKEN"]
    ns = os.environ.get("GRAFANA_DASHBOARD_NAMESPACE") or f"stacks-{os.environ['GC_OTLP_ACCOUNT']}"
    for uid, filename in UIDS.items():
        req = urllib.request.Request(
            f"{base}/apis/dashboard.grafana.app/v2/namespaces/{ns}/dashboards/{uid}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=180) as resp:
            live = json.loads(resp.read().decode())
        # Strip runtime metadata for repo storage
        for k in ("resourceVersion", "generation", "creationTimestamp", "uid", "managedFields"):
            live.get("metadata", {}).pop(k, None)
        live.get("metadata", {}).pop("namespace", None)
        live.pop("status", None)
        path = REPO / "dashboards" / filename
        path.write_text(json.dumps(live, indent=2) + "\n", encoding="utf-8")
        kind = live["spec"]["layout"]["kind"]
        print(f"pulled {uid} layout={kind} -> {path.name}")


if __name__ == "__main__":
    main()
