#!/usr/bin/env python3
"""Split one discovery device list into per-vendor poller files.

After a ROLE=discover scan publishes state/devices-<source>.yaml, this script
routes each device into state/devices-<vendor>.yaml using mib_profile / sysObjectID
rules from config/vendor-split.yaml (see examples/vendor-split/).

The poller for each vendor @-includes only its file. SIGUSR2 that poller
(scripts/reload-ktranslate-devices.sh) — no container restart.

Usage:
  python3 scripts/split-devices-by-vendor.py
  python3 scripts/split-devices-by-vendor.py --dry-run
  python3 scripts/split-devices-by-vendor.py --self-test
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _yaml():
    try:
        import yaml
    except ImportError as exc:
        raise SystemExit(
            "split-devices-by-vendor.py needs PyYAML — install with: sudo apt install python3-yaml"
        ) from exc
    return yaml


def load_yaml(path: Path) -> object:
    yaml = _yaml()
    with path.open(encoding="utf-8") as fh:
        data = yaml.safe_load(fh)
    return {} if data is None else data


def write_yaml(data: object, path: Path) -> None:
    yaml = _yaml()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            yaml.safe_dump(
                data,
                fh,
                default_flow_style=False,
                sort_keys=False,
                allow_unicode=True,
            )
        tmp.replace(path)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def normalize_oid(oid: str) -> str:
    return (oid or "").strip().lstrip(".")


def as_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value if v is not None and str(v) != ""]
    return [str(value)]


def match_device(device: dict, rule: dict) -> bool:
    profile = str(device.get("mib_profile") or device.get("MibProfile") or "")
    oid = normalize_oid(str(device.get("oid") or device.get("OID") or ""))
    provider = str(device.get("provider") or device.get("Provider") or "")

    for pat in as_list(rule.get("mib_profile")):
        if fnmatch.fnmatch(profile.lower(), pat.lower()):
            return True
    for prefix in as_list(rule.get("oid_prefix")):
        if oid.startswith(normalize_oid(prefix)):
            return True
    for pat in as_list(rule.get("provider")):
        if fnmatch.fnmatch(provider.lower(), pat.lower()):
            return True
    return False


def load_devices(path: Path) -> dict:
    data = load_yaml(path)
    if data is None or data == {}:
        return {}
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: expected a YAML map of devices, got {type(data).__name__}")
    # Tolerate a wrapped {devices: {...}} if someone copied the runtime file.
    if "devices" in data and isinstance(data["devices"], dict) and "device_ip" not in data:
        inner = data["devices"]
        if inner and all(isinstance(v, dict) for v in inner.values()):
            return inner
    return data


def split_devices(devices: dict, mapping: dict) -> dict[str, dict]:
    default = mapping.get("default_group") or "other"
    rules = mapping.get("rules") or []
    buckets: dict[str, dict] = {default: {}}
    for rule in rules:
        dest = rule.get("group")
        if dest:
            buckets.setdefault(dest, {})

    for key, device in devices.items():
        if not isinstance(device, dict):
            buckets[default][key] = device
            continue
        dest = default
        for rule in rules:
            if match_device(device, rule):
                dest = rule.get("group") or default
                break
        buckets.setdefault(dest, {})[key] = device
    return buckets


def mapping_path(explicit: Path | None) -> Path:
    if explicit:
        return explicit
    preferred = REPO / "config" / "vendor-split.yaml"
    if preferred.is_file():
        return preferred
    return REPO / "examples" / "vendor-split" / "vendor-split.yaml"


def self_test() -> int:
    testdata = REPO / "examples" / "vendor-split" / "testdata" / "devices-estate.yaml"
    mapping_file = REPO / "examples" / "vendor-split" / "vendor-split.yaml"
    devices = load_devices(testdata)
    mapping = load_yaml(mapping_file)
    if not isinstance(mapping, dict):
        raise SystemExit(f"{mapping_file}: expected a mapping document")
    buckets = split_devices(devices, mapping)
    expect = {
        "cisco": {"core1"},
        "palo": {"fw1"},
        "juniper": {"ex1"},
        "other": {"ups1"},
    }
    failed = False
    for group, names in expect.items():
        got = set(buckets.get(group, {}))
        if got != names:
            print(f"FAIL {group}: expected {names}, got {got}", file=sys.stderr)
            failed = True
        else:
            print(f"ok   {group}: {sorted(got)}")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mapping", type=Path, help="vendor-split.yaml (default: config/ then examples/)")
    ap.add_argument("--from", dest="source", type=Path, help="override source devices YAML")
    ap.add_argument("--state-dir", type=Path, default=REPO / "state")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    mpath = mapping_path(args.mapping)
    if not mpath.is_file():
        print(f"no vendor-split mapping at {mpath}", file=sys.stderr)
        print("copy examples/vendor-split/vendor-split.yaml → config/vendor-split.yaml", file=sys.stderr)
        return 1

    mapping = load_yaml(mpath)
    if not isinstance(mapping, dict):
        print(f"{mpath}: expected a YAML mapping", file=sys.stderr)
        return 1
    source_group = mapping.get("source_group") or "estate"
    src = args.source or (args.state_dir / f"devices-{source_group}.yaml")
    if not src.is_file():
        print(f"missing source device list: {src}", file=sys.stderr)
        print(f"run: make discover GROUP={source_group}", file=sys.stderr)
        return 1

    devices = load_devices(src)
    buckets = split_devices(devices, mapping)

    known_pollers = set()
    for env_file in sorted((REPO / "groups").glob("*.env")):
        role = "both"
        group = ""
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("GROUP="):
                group = line.split("=", 1)[1].strip()
            elif line.startswith("ROLE="):
                role = line.split("=", 1)[1].strip() or "both"
        if group and role != "discover":
            known_pollers.add(group)

    print(f"split {len(devices)} devices from {src.name} using {mpath}")
    for group, bucket in sorted(buckets.items()):
        dest = args.state_dir / f"devices-{group}.yaml"
        if known_pollers and group not in known_pollers:
            print(f"  skip {group} ({len(bucket)} devices) — no groups/{group}.env poller")
            continue
        if args.dry_run:
            print(f"  {group}: {len(bucket)} devices → {dest.name} (dry-run)")
            continue
        write_yaml(bucket if bucket else {}, dest)
        print(f"  {group}: {len(bucket)} devices → {dest.name}")

    if args.dry_run:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
