#!/usr/bin/env python3
"""Union each device's discovered_mibs into poller global.mibs_enabled.

ktranslate only walks global.mibs_enabled. Discovery records the full profile
set on each device; this copies that union onto the generated poller without
rewriting the rest of the YAML.

Usage:
  apply-discovered-mibs.py <poller.yaml> <devices.yaml> [out.yaml]
  apply-discovered-mibs.py --pin IF-MIB,BGP4-MIB <poller.yaml> [out.yaml]

Exit codes:
  0  already matched
  1  error
  2  skipped (no devices file)
  3  wrote an updated list
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "apply-discovered-mibs: PyYAML is required (sudo apt install python3-yaml)\n"
    )
    sys.exit(1)


def _load(path: Path) -> object:
    with path.open(encoding="utf-8") as fh:
        return yaml.safe_load(fh) or {}


def _device_map(raw: object) -> dict:
    if isinstance(raw, dict) and isinstance(raw.get("devices"), dict):
        return raw["devices"]
    if isinstance(raw, dict):
        return raw
    return {}


def _union_mibs(seed: list[str], devices: dict) -> list[str]:
    found = {str(x) for x in seed if x}
    for dev in devices.values():
        if not isinstance(dev, dict):
            continue
        for mib in dev.get("discovered_mibs") or []:
            if mib:
                found.add(str(mib))
    return sorted(found)


def _current_mibs(path: Path) -> list[str]:
    if not path.is_file():
        return []
    doc = _load(path)
    if isinstance(doc, dict) and isinstance(doc.get("global"), dict):
        return [str(x) for x in (doc["global"].get("mibs_enabled") or []) if x]
    return []


def _rewrite_mibs_block(src: Path, dest: Path, mibs: list[str]) -> None:
    text = src.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    start = None
    key_indent = None
    for i, line in enumerate(lines):
        if line.lstrip(" ").startswith("mibs_enabled:"):
            start = i
            key_indent = len(line) - len(line.lstrip(" "))
            break
    if start is None or key_indent is None:
        raise SystemExit(f"apply-discovered-mibs: no mibs_enabled: key in {src}")
    item_indent = key_indent + 2
    end = start + 1
    while end < len(lines):
        raw = lines[end]
        if raw.strip() == "":
            break
        leading = len(raw) - len(raw.lstrip(" "))
        if raw.lstrip(" ").startswith("- ") and leading >= item_indent:
            end += 1
            continue
        break
    block = [" " * key_indent + "mibs_enabled:\n"]
    for mib in mibs:
        block.append(f"{' ' * item_indent}- {mib}\n")
    dest.write_text("".join(lines[:start] + block + lines[end:]), encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--pin", metavar="CSV", help="replace mibs_enabled with this list")
    parser.add_argument("poller")
    parser.add_argument("devices", nargs="?")
    parser.add_argument("out", nargs="?")
    args = parser.parse_args(argv[1:])

    poller_path = Path(args.poller)
    if args.pin:
        out_path = Path(args.devices) if args.devices else poller_path
        devices_path = None
        merged = [p.strip() for p in args.pin.split(",") if p.strip()]
    else:
        if not args.devices:
            parser.error("devices.yaml is required unless --pin is set")
        devices_path = Path(args.devices)
        out_path = Path(args.out) if args.out else poller_path
        merged = None

    if not poller_path.is_file():
        sys.stderr.write(f"apply-discovered-mibs: missing {poller_path}\n")
        return 1

    if merged is None:
        seed = _current_mibs(poller_path)
        if devices_path is None or not devices_path.is_file():
            if out_path != poller_path:
                out_path.write_text(poller_path.read_text(encoding="utf-8"), encoding="utf-8")
            print(
                f"apply-discovered-mibs: no devices file yet ({devices_path}); seed mibs_enabled only"
            )
            return 2
        merged = _union_mibs(seed, _device_map(_load(devices_path)))

    old = _current_mibs(out_path) if out_path.is_file() else []
    if old == merged and out_path.is_file():
        print(f"apply-discovered-mibs: mibs_enabled unchanged ({', '.join(merged)})")
        return 0

    src = out_path if out_path.is_file() else poller_path
    if out_path != poller_path and not out_path.is_file():
        out_path.write_text(poller_path.read_text(encoding="utf-8"), encoding="utf-8")
        src = out_path
    _rewrite_mibs_block(src, out_path, merged)
    print(f"apply-discovered-mibs: mibs_enabled updated: {', '.join(merged)}")
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
