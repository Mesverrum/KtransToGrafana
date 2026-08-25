#!/usr/bin/env python3
"""Split one discovery device list into poller files using a YAML mapping.

After a ROLE=discover scan publishes state/devices-<source>.yaml, this script
routes each device into state/devices-<group>.yaml. Match on any field the
device list holds (profile, OID, hostname, IP, sysDescr, user_tags, …) —
edit the YAML, do not write a new script.

    python3 scripts/split-devices.py
    python3 scripts/split-devices.py --dry-run --explain
    python3 scripts/split-devices.py --dry-run --explain --ignore-pollers
    python3 scripts/split-devices.py --list-fields
    python3 scripts/split-devices.py --list-values mib_profile
    python3 scripts/split-devices.py --self-test

Mapping lookup (first file that exists):
  config/device-split.yaml
  config/vendor-split.yaml
  examples/vendor-split/device-split.yaml
"""
from __future__ import annotations

import argparse
import fnmatch
import ipaddress
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]

FIELD_ALIASES = {
    "hostname": "device_name",
    "name": "device_name",
    "ip": "device_ip",
    "address": "device_ip",
    "sysobjectid": "oid",
    "sysoid": "oid",
    "profile": "mib_profile",
    "sysdescr": "description",
    "descr": "description",
    "firmware": "description",
}

MAPPING_CANDIDATES = (
    REPO / "config" / "device-split.yaml",
    REPO / "config" / "vendor-split.yaml",
    REPO / "examples" / "vendor-split" / "device-split.yaml",
    REPO / "examples" / "vendor-split" / "vendor-split.yaml",
)


def _yaml():
    try:
        import yaml
    except ImportError as exc:
        raise SystemExit(
            "split-devices.py needs PyYAML — install with: sudo apt install python3-yaml"
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


def as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v) for v in value if v is not None and str(v) != ""]
    return [str(value)]


def normalize_oid(oid: str) -> str:
    return (oid or "").strip().lstrip(".")


def field_value(device: dict, path: str) -> Any:
    key = FIELD_ALIASES.get(path.lower(), path)
    cur: Any = device
    for part in key.split("."):
        if not isinstance(cur, dict):
            return None
        found = None
        if part in cur:
            found = cur[part]
        else:
            want = part.lower()
            for k, v in cur.items():
                if str(k).lower() == want:
                    found = v
                    break
        if found is None:
            return None
        cur = found
    return cur


def stringify(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


@dataclass
class ClauseHit:
    ok: bool
    captures: list[str] = field(default_factory=list)
    reason: str = ""


def _casefold(s: str, sensitive: bool) -> str:
    return s if sensitive else s.casefold()


def canonical_field(path: str) -> str:
    return FIELD_ALIASES.get(path.lower(), path)


def eval_clause(device: dict, clause: dict) -> ClauseHit:
    if not isinstance(clause, dict):
        return ClauseHit(False, reason="clause is not a map")
    path = str(clause.get("field") or "")
    if not path:
        return ClauseHit(False, reason="clause missing field")
    raw = field_value(device, path)
    text = stringify(raw)
    sensitive = str(clause.get("case") or "").lower() in {"sensitive", "exact"}
    negate = bool(clause.get("not") or clause.get("negate"))
    canon = canonical_field(path)
    oid_field = canon.lower() in {"oid"} or path.lower() in {"oid", "sysobjectid", "sysoid"}

    hit = ClauseHit(False, reason=f"{path} unmatched")

    if "equals" in clause or "eq" in clause:
        needles = as_list(clause.get("equals", clause.get("eq")))
        ok = any(_casefold(text, sensitive) == _casefold(n, sensitive) for n in needles)
        hit = ClauseHit(ok, reason=f"{path} equals {needles}")
    elif "in" in clause:
        needles = as_list(clause["in"])
        ok = any(_casefold(text, sensitive) == _casefold(n, sensitive) for n in needles)
        hit = ClauseHit(ok, reason=f"{path} in {needles}")
    elif "glob" in clause:
        pats = as_list(clause["glob"])
        hay = _casefold(text, sensitive)
        ok = any(fnmatch.fnmatch(hay, _casefold(p, sensitive)) for p in pats)
        hit = ClauseHit(ok, reason=f"{path} glob {pats}")
    elif "contains" in clause or "substring" in clause:
        needles = as_list(clause.get("contains", clause.get("substring")))
        hay = _casefold(text, sensitive)
        ok = any(_casefold(n, sensitive) in hay for n in needles)
        hit = ClauseHit(ok, reason=f"{path} contains {needles}")
    elif "prefix" in clause:
        prefixes = as_list(clause["prefix"])
        if oid_field:
            hay = normalize_oid(text)
            ok = any(hay.startswith(normalize_oid(p)) for p in prefixes)
        else:
            hay2 = _casefold(text, sensitive)
            ok = any(hay2.startswith(_casefold(p, sensitive)) for p in prefixes)
        hit = ClauseHit(ok, reason=f"{path} prefix {prefixes}")
    elif "regex" in clause:
        pats = as_list(clause["regex"])
        flags = 0 if sensitive else re.IGNORECASE
        for pat in pats:
            m = re.search(pat, text, flags)
            if m:
                hit = ClauseHit(True, captures=list(m.groups()), reason=f"{path} regex {pat}")
                break
        else:
            hit = ClauseHit(False, reason=f"{path} regex {pats}")
    elif "cidr" in clause:
        nets = as_list(clause["cidr"])
        ok = False
        try:
            addr = ipaddress.ip_address(text.split("/")[0].strip())
        except ValueError:
            addr = None
        if addr is not None:
            for n in nets:
                try:
                    network = ipaddress.ip_network(n, strict=False)
                except ValueError:
                    continue
                if addr in network:
                    ok = True
                    break
        hit = ClauseHit(ok, reason=f"{path} cidr {nets}")
    elif "exists" in clause:
        want = bool(clause["exists"])
        present = raw is not None and stringify(raw) != ""
        hit = ClauseHit(present is want, reason=f"{path} exists={want}")
    else:
        return ClauseHit(False, reason=f"{path} has no operator")

    if negate:
        hit.ok = not hit.ok
        hit.reason = "not (" + hit.reason + ")"
        if not hit.ok:
            hit.captures = []
    return hit


def compile_any_all(rule: dict) -> tuple[list, list]:
    """Return (any_clauses, all_clauses). Shorthand fields OR together."""
    any_c = list(rule.get("any") or rule.get("or") or [])
    all_c = list(rule.get("all") or rule.get("match") or [])
    if "mib_profile" in rule:
        any_c.append({"field": "mib_profile", "glob": rule["mib_profile"]})
    if "oid_prefix" in rule:
        any_c.append({"field": "oid", "prefix": rule["oid_prefix"]})
    if "provider" in rule:
        any_c.append({"field": "provider", "glob": rule["provider"]})
    return any_c, all_c


@dataclass
class RuleHit:
    ok: bool
    group: str = ""
    captures: list[str] = field(default_factory=list)
    reason: str = ""
    index: int = 0


def slug_group(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "-", name.strip())
    cleaned = cleaned.strip("-._")
    return cleaned or "other"


def transform_value(value: str, how: str) -> str:
    text = stringify(value)
    for part in as_list(how) or ["identity"]:
        p = part.lower()
        if p in {"identity", "id", ""}:
            continue
        if p in {"lower", "casefold"}:
            text = text.casefold()
        elif p == "upper":
            text = text.upper()
        elif p in {"stem", "basename"}:
            text = Path(text).stem
        elif p == "slug":
            text = slug_group(text).casefold()
    return text


def resolve_group(rule: dict, device: dict, captures: list[str]) -> str:
    if rule.get("group_from"):
        raw = field_value(device, str(rule["group_from"]))
        return slug_group(transform_value(stringify(raw), rule.get("group_transform") or "stem"))
    template = str(rule.get("group") or "")
    if not template:
        return ""
    out = template
    for i, cap in enumerate(captures, start=1):
        out = out.replace(f"{{{i}}}", cap)
        out = out.replace(f"${i}", cap)
    # {field.path} substitutions
    for m in list(re.finditer(r"\{([A-Za-z0-9_.]+)\}", out)):
        key = m.group(1)
        if key.isdigit():
            continue
        val = stringify(field_value(device, key))
        out = out.replace(m.group(0), val)
    return slug_group(out) if out != template or "{" not in template else slug_group(out)


def eval_rule(device: dict, rule: dict, index: int) -> RuleHit:
    any_c, all_c = compile_any_all(rule)
    captures: list[str] = []
    reasons: list[str] = []

    if any_c:
        any_ok = False
        for clause in any_c:
            hit = eval_clause(device, clause)
            if hit.ok:
                any_ok = True
                captures = hit.captures or captures
                reasons.append(hit.reason)
                break
        if not any_ok:
            return RuleHit(False, reason="no any-clause matched", index=index)
    if all_c:
        for clause in all_c:
            hit = eval_clause(device, clause)
            if not hit.ok:
                return RuleHit(False, reason=hit.reason, index=index)
            if hit.captures:
                captures = hit.captures
            reasons.append(hit.reason)

    if not any_c and not all_c and not rule.get("group_from"):
        return RuleHit(False, reason="rule has no matchers", index=index)

    # Bare group_from with no matchers: matches everything remaining.
    dest = resolve_group(rule, device, captures)
    if not dest:
        return RuleHit(False, reason="empty destination group", index=index)
    return RuleHit(True, group=dest, captures=captures, reason="; ".join(reasons) or "group_from", index=index)


def known_poller_map(groups_dir: Path) -> dict[str, str]:
    """casefold name → GROUP= as spelled in groups/*.env (pollers only)."""
    out: dict[str, str] = {}
    if not groups_dir.is_dir():
        return out
    for env_file in sorted(groups_dir.glob("*.env")):
        role = "both"
        group = ""
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("GROUP="):
                group = line.split("=", 1)[1].strip()
            elif line.startswith("ROLE="):
                role = line.split("=", 1)[1].strip() or "both"
        if group and role != "discover":
            out[group.casefold()] = group
    return out


def split_devices(
    devices: dict,
    mapping: dict,
    pollers: dict[str, str] | None = None,
) -> tuple[dict[str, dict], list[tuple[str, str, str]]]:
    """Return (buckets, explain rows of (device_key, group, reason))."""
    default = mapping.get("default_group") or "other"
    rules = mapping.get("rules") or []
    buckets: dict[str, dict] = {default: {}}
    explain: list[tuple[str, str, str]] = []

    for key, device in devices.items():
        if not isinstance(device, dict):
            buckets.setdefault(default, {})[key] = device
            explain.append((str(key), default, "not a device map"))
            continue
        dest = default
        reason = f"default_group ({default})"
        skipped: list[str] = []
        for i, rule in enumerate(rules, start=1):
            if not isinstance(rule, dict):
                continue
            hit = eval_rule(device, rule, i)
            if not hit.ok:
                continue
            cand = hit.group
            if pollers:
                spelled = pollers.get(cand.casefold())
                if spelled is None:
                    skipped.append(f"rule {i} → {cand} (no poller)")
                    continue  # try the next rule; do not drop the device
                cand = spelled
            dest = cand
            reason = f"rule {i}: {hit.reason}" if hit.reason else f"rule {i}"
            break
        if dest == default and skipped:
            reason = f"{reason}; skipped {'; '.join(skipped)}"
        buckets.setdefault(dest, {})[key] = device
        explain.append((str(key), dest, reason))
    return buckets, explain


def load_devices(path: Path) -> dict:
    data = load_yaml(path)
    if data is None or data == {}:
        return {}
    if not isinstance(data, dict):
        raise SystemExit(f"{path}: expected a YAML map of devices, got {type(data).__name__}")
    if "devices" in data and isinstance(data["devices"], dict) and "device_ip" not in data:
        inner = data["devices"]
        if inner and all(isinstance(v, dict) for v in inner.values()):
            return inner
    return data


def mapping_path(explicit: Path | None) -> Path | None:
    if explicit:
        return explicit
    for cand in MAPPING_CANDIDATES:
        if cand.is_file():
            return cand
    return None


def iter_field_paths(obj: Any, prefix: str = ""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            path = f"{prefix}.{k}" if prefix else str(k)
            if isinstance(v, dict):
                yield from iter_field_paths(v, path)
            else:
                yield path, v


def cmd_list_fields(devices: dict) -> int:
    samples: dict[str, list[str]] = {}
    for device in devices.values():
        if not isinstance(device, dict):
            continue
        for path, val in iter_field_paths(device):
            bucket = samples.setdefault(path, [])
            s = stringify(val)
            if s and s not in bucket and len(bucket) < 8:
                bucket.append(s)
    if not samples:
        print("no fields found")
        return 0
    width = max(len(p) for p in samples)
    print(f"{'field':<{width}}  sample values")
    for path in sorted(samples):
        print(f"{path:<{width}}  {', '.join(samples[path])}")
    return 0


def cmd_list_values(devices: dict, path: str) -> int:
    counts: dict[str, int] = {}
    missing = 0
    for device in devices.values():
        if not isinstance(device, dict):
            continue
        val = field_value(device, path)
        if val is None or stringify(val) == "":
            missing += 1
            continue
        s = stringify(val)
        counts[s] = counts.get(s, 0) + 1
    if not counts:
        print(f"no values for {path} ({missing} devices missing the field)")
        return 0
    for val, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"{n:5}  {val}")
    if missing:
        print(f"{missing:5}  (missing)")
    return 0


def self_test() -> int:
    testdata = REPO / "examples" / "vendor-split" / "testdata" / "devices-estate.yaml"
    devices = load_devices(testdata)
    failed = 0

    def check(title: str, mapping: dict, expect: dict[str, set[str]], pollers=None) -> None:
        nonlocal failed
        buckets, _ = split_devices(devices, mapping, pollers)
        for group, names in expect.items():
            got = set(buckets.get(group, {}))
            if got != names:
                print(f"FAIL {title} / {group}: expected {names}, got {got}", file=sys.stderr)
                failed += 1
            else:
                print(f"ok   {title} / {group}: {sorted(got)}")

    vendor = load_yaml(REPO / "examples" / "vendor-split" / "vendor-split.yaml")
    check(
        "vendor shorthand",
        vendor,
        {"cisco": {"core1", "hq-leaf", "br-leaf"}, "palo": {"fw1"}, "juniper": {"ex1"}, "other": {"ups1"}},
    )

    check(
        "cidr sites",
        {
            "default_group": "other",
            "rules": [
                {"group": "hq", "match": [{"field": "device_ip", "cidr": "10.10.0.0/16"}]},
                {"group": "branch", "match": [{"field": "device_ip", "cidr": "10.20.0.0/16"}]},
            ],
        },
        {"hq": {"hq-leaf"}, "branch": {"br-leaf"}, "other": {"core1", "fw1", "ex1", "ups1"}},
    )

    check(
        "hostname regex capture",
        {
            "default_group": "other",
            "rules": [{"group": "site-{1}", "match": [{"field": "device_name", "regex": r"^(dc\d+)-"}]}],
        },
        {"site-dc1": {"core1"}, "site-dc2": {"ex1"}, "other": {"fw1", "ups1", "hq-leaf", "br-leaf"}},
    )

    check(
        "description firmware",
        {
            "default_group": "other",
            "rules": [{"group": "iosxe17", "match": [{"field": "description", "regex": r"17\.9"}]}],
        },
        {"iosxe17": {"br-leaf"}, "other": {"core1", "fw1", "ex1", "ups1", "hq-leaf"}},
    )

    check(
        "AND profile+subnet",
        {
            "default_group": "other",
            "rules": [
                {
                    "group": "hq-cisco",
                    "match": [
                        {"field": "mib_profile", "glob": "cisco*"},
                        {"field": "device_ip", "cidr": "10.10.0.0/16"},
                    ],
                }
            ],
        },
        {"hq-cisco": {"hq-leaf"}, "other": {"core1", "fw1", "ex1", "ups1", "br-leaf"}},
    )

    check(
        "nested user_tags",
        {
            "default_group": "other",
            "rules": [{"group": "tagged-hq", "match": [{"field": "user_tags.site", "equals": "hq"}]}],
        },
        {"tagged-hq": {"hq-leaf"}, "other": {"core1", "fw1", "ex1", "ups1", "br-leaf"}},
    )

    check(
        "unknown dest falls through",
        {
            "default_group": "other",
            "rules": [
                {"group": "no-such-poller", "match": [{"field": "mib_profile", "glob": "cisco*"}]},
                {"group": "cisco", "match": [{"field": "mib_profile", "glob": "cisco*"}]},
            ],
        },
        {"cisco": {"core1", "hq-leaf", "br-leaf"}, "other": {"fw1", "ex1", "ups1"}},
        pollers={"cisco": "cisco", "other": "other"},
    )

    check(
        "any OR profiles",
        {
            "default_group": "other",
            "rules": [
                {
                    "group": "network",
                    "any": [
                        {"field": "mib_profile", "glob": "palo*"},
                        {"field": "mib_profile", "glob": "juniper*"},
                    ],
                }
            ],
        },
        {"network": {"fw1", "ex1"}, "other": {"core1", "hq-leaf", "br-leaf", "ups1"}},
    )

    check(
        "group_from profile stem",
        {
            "default_group": "other",
            "rules": [{"group_from": "mib_profile", "group_transform": "stem"}],
        },
        {
            "cisco-nexus": {"core1"},
            "paloalto": {"fw1"},
            "juniper-ex": {"ex1"},
            "apc_ups": {"ups1"},
            "cisco-catalyst": {"hq-leaf"},
            "cisco-iosxe": {"br-leaf"},
        },
    )

    generic = {
        "field": "mib_profile",
        "glob": "cisco*",
    }
    hit = eval_clause(devices["core1"], generic)
    if not hit.ok:
        print("FAIL glob cisco* on core1", file=sys.stderr)
        failed += 1
    else:
        print("ok   clause glob")

    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mapping", type=Path, help="device-split YAML (default: config/ then examples/)")
    ap.add_argument("--from", dest="source", type=Path, help="override source devices YAML")
    ap.add_argument("--state-dir", type=Path, default=REPO / "state")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--explain", action="store_true", help="print which rule caught each device")
    ap.add_argument(
        "--ignore-pollers",
        action="store_true",
        help="do not require groups/<name>.env (preview buckets before creating pollers)",
    )
    ap.add_argument("--list-fields", action="store_true", help="show fields present on the source list")
    ap.add_argument("--list-values", metavar="FIELD", help="count distinct values of FIELD")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    mpath = mapping_path(args.mapping)
    source_group = "estate"
    mapping: dict = {}
    if mpath and mpath.is_file():
        loaded = load_yaml(mpath)
        if isinstance(loaded, dict):
            mapping = loaded
            source_group = mapping.get("source_group") or source_group
        elif not (args.list_fields or args.list_values):
            print(f"{mpath}: expected a YAML mapping", file=sys.stderr)
            return 1
    elif not (args.list_fields or args.list_values):
        print("no device-split mapping found. Copy examples/vendor-split/device-split.yaml", file=sys.stderr)
        print("  → config/device-split.yaml  (or --mapping PATH)", file=sys.stderr)
        return 1

    src = args.source or (args.state_dir / f"devices-{source_group}.yaml")
    if args.list_fields or args.list_values:
        if args.source:
            src = args.source
        elif not src.is_file():
            src = REPO / "examples" / "vendor-split" / "testdata" / "devices-estate.yaml"
    if not src.is_file():
        print(f"missing source device list: {src}", file=sys.stderr)
        print(f"run: make discover GROUP={source_group}", file=sys.stderr)
        return 1

    devices = load_devices(src)
    if args.list_fields:
        return cmd_list_fields(devices)
    if args.list_values:
        return cmd_list_values(devices, args.list_values)

    pollers = None if args.ignore_pollers else known_poller_map(REPO / "groups")
    buckets, explain = split_devices(devices, mapping, pollers or None)

    print(f"split {len(devices)} devices from {src.name} using {mpath}")
    if args.explain:
        width = max((len(k) for k, _, _ in explain), default=8)
        for key, group, reason in explain:
            print(f"  {key:<{width}} → {group}  ({reason})")

    for group, bucket in sorted(buckets.items()):
        dest = args.state_dir / f"devices-{group}.yaml"
        if pollers and group.casefold() not in pollers:
            print(f"  skip {group} ({len(bucket)} devices) — no groups/{group}.env poller")
            continue
        if args.dry_run:
            print(f"  {group}: {len(bucket)} devices → {dest.name} (dry-run)")
            continue
        write_yaml(bucket if bucket else {}, dest)
        print(f"  {group}: {len(bucket)} devices → {dest.name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
