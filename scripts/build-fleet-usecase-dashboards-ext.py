#!/usr/bin/env python3
"""Build KtransToGrafana fleet use-case dashboards 08–10 (Events, Environment, Adjacency).

Usage:
  python3 scripts/build-fleet-usecase-dashboards-ext.py --push
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import ssl
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
DASH_DIR = REPO / "dashboards"

_spec = importlib.util.spec_from_file_location(
    "fleet_base", REPO / "scripts" / "build-fleet-usecase-dashboards.py"
)
_base = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(_base)

SEL = _base.SEL
VIZ = _base.VIZ
DS = _base.DS
LOKI = {"name": "$loki"}


def load_env() -> None:
    _base.load_env()


def fleet_vars_with_loki() -> list[dict]:
    vars_ = _base.fleet_vars()
    vars_.insert(
        1,
        {
            "kind": "DatasourceVariable",
            "spec": {
                "name": "loki",
                "pluginId": "loki",
                "refresh": "onDashboardLoad",
                "regex": "",
                "current": {"text": "default", "value": "default"},
                "options": [],
                "multi": False,
                "includeAll": False,
                "label": "Loki data source",
                "hide": "dontHide",
                "skipUrlSync": False,
                "allowCustomValue": True,
            },
        },
    )
    return vars_


def loki_query(expr: str, *, legend: str = "__auto") -> dict:
    return {
        "kind": "PanelQuery",
        "spec": {
            "query": {
                "kind": "DataQuery",
                "group": "loki",
                "version": "v0",
                "datasource": LOKI,
                "spec": {
                    "expr": expr,
                    "instant": False,
                    "range": True,
                    "legendFormat": legend,
                    "queryType": "range",
                },
            },
            "refId": "A",
            "hidden": False,
        },
    }


def panel_loki(
    pid: int,
    title: str,
    viz: str,
    expr: str,
    *,
    description: str = "",
    legend: str = "__auto",
    field_defaults: dict | None = None,
) -> dict:
    defaults = field_defaults or {"unit": "short", "min": 0}
    if viz == "logs":
        viz_opts = {
            "showTime": True,
            "showLabels": False,
            "showCommonLabels": False,
            "wrapLogMessage": True,
            "prettifyLogMessage": False,
            "enableLogDetails": True,
            "dedupStrategy": "none",
            "sortOrder": "Descending",
        }
    else:
        viz_opts = {
            "legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        }
    return {
        "kind": "Panel",
        "spec": {
            "id": pid,
            "title": title,
            "description": description,
            "links": [],
            "data": {
                "kind": "QueryGroup",
                "spec": {
                    "queries": [loki_query(expr, legend=legend)],
                    "transformations": [],
                    "queryOptions": {},
                },
            },
            "vizConfig": {
                "kind": "VizConfig",
                "group": viz,
                "version": VIZ,
                "spec": {
                    "options": viz_opts,
                    "fieldConfig": {"defaults": defaults, "overrides": []},
                },
            },
        },
    }


def dashboard(uid: str, title: str, description: str, elements: dict, tabs: list, *, loki: bool = False) -> dict:
    d = _base.dashboard(uid, title, description, elements, tabs)
    if loki:
        d["spec"]["variables"] = fleet_vars_with_loki()
    return d


def build_events() -> dict:
    els: dict[str, dict] = {}
    pid = 800
    panel = _base.panel
    add = None

    def add_prom(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel(pid, title, viz, expr, **kw)
        return key

    def add_loki(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel_loki(pid, title, viz, expr, **kw)
        return key

    p_trap_tot = add_loki(
        "stat",
        "Traps (range)",
        'sum(count_over_time({service_name=~"ktranslate.*"} | json | eventType="KSnmpTrap" [$__range]))',
        description="Total SNMP trap events in the dashboard time range.",
    )
    # Fix: panel_loki always uses range query - for stat that's ok with lastNotNull on timeseries-like
    # Actually loki_query is always range - for stat Grafana reduces. Good.

    p_sys_tot = add_loki(
        "stat",
        "Syslog lines (range)",
        'sum(count_over_time({service_name=~"ktranslate.*"} | json | instrumentation_name="ktranslate-syslog" [$__range]))',
    )
    p_trap_dev = add_loki(
        "timeseries",
        "Trap volume by device",
        'sum by (device_name) (count_over_time({service_name=~"ktranslate.*"} | json | eventType="KSnmpTrap" | device_name=~"$device_name" [$__interval]))',
        legend="{{device_name}}",
    )
    p_sys_dev = add_loki(
        "timeseries",
        "Syslog volume by device",
        'sum by (device_name) (count_over_time({service_name=~"ktranslate.*"} | json | instrumentation_name="ktranslate-syslog" | device_name=~"$device_name" [$__interval]))',
        legend="{{device_name}}",
    )
    p_trap_types = add_loki(
        "piechart",
        "Trap types (range)",
        'sum by (TrapName) (count_over_time({service_name=~"ktranslate.*"} | json | eventType="KSnmpTrap" | TrapName != "" [$__range]))',
        legend="{{TrapName}}",
    )
    p_sev = add_loki(
        "timeseries",
        "Syslog by severity",
        'sum by (severity) (count_over_time({service_name=~"ktranslate.*"} | json | instrumentation_name="ktranslate-syslog" | severity != "" [$__interval]))',
        legend="{{severity}}",
    )
    p_noisy = add_loki(
        "timeseries",
        "Top noisy devices (traps + syslog)",
        'sum by (device_name) (count_over_time({service_name=~"ktranslate.*"} | json | eventType="KSnmpTrap" | device_name=~"$device_name" [$__interval]))',
        legend="traps {{device_name}}",
        description="Trap rate per device — pair with syslog panel to spot chatter.",
    )
    p_link = add_loki(
        "timeseries",
        "Link flap traps",
        'sum by (device_name, TrapName) (count_over_time({service_name=~"ktranslate.*"} | json | eventType="KSnmpTrap" | TrapName =~ "(?i).*link.*" [$__interval]))',
        legend="{{device_name}} {{TrapName}}",
        description="TrapName matching /link/i (linkUp/linkDown and vendor variants).",
    )
    p_recent_traps = add_loki(
        "logs",
        "Recent SNMP traps",
        '{service_name=~"ktranslate.*"} | json | eventType="KSnmpTrap" | device_name=~"$device_name"',
    )
    p_recent_sys = add_loki(
        "logs",
        "Recent device syslog",
        '{service_name=~"ktranslate.*"} | json | instrumentation_name="ktranslate-syslog" | device_name=~"$device_name"',
    )
    # ifOperStatus churn proxy via down count (prom)
    p_if_down = add_prom(
        "stat",
        "Admin-up interfaces down",
        f'count(kentik_snmp_if_OperStatus{{{SEL},if_AdminStatus!="down"}} != 1) OR vector(0)',
        description="Live oper-down count (admin-up only) — correlate with link flaps.",
    )

    # Fix piechart/stat for loki - panel_loki uses timeseries opts for non-logs
    # Rebuild pie/stat with proper viz options by patching after
    for key in (p_trap_tot, p_sys_tot):
        els[key]["spec"]["vizConfig"]["group"] = "stat"
        els[key]["spec"]["vizConfig"]["spec"]["options"] = {
            "colorMode": "value",
            "graphMode": "none",
            "reduceOptions": {"calcs": ["sum"], "fields": "", "values": False},
            "textMode": "auto",
        }
    els[p_trap_types]["spec"]["vizConfig"]["group"] = "piechart"
    els[p_trap_types]["spec"]["vizConfig"]["spec"]["options"] = {
        "legend": {"displayMode": "list", "placement": "right", "showLegend": True},
        "pieType": "pie",
        "reduceOptions": {"calcs": ["sum"], "fields": "", "values": False},
    }

    tabs = [
        _base.tab(
            "Overview",
            [
                _base.row(
                    "Volume",
                    [
                        _base.grid_item(p_trap_tot, 0, 0, 8, 5),
                        _base.grid_item(p_sys_tot, 8, 0, 8, 5),
                        _base.grid_item(p_if_down, 16, 0, 8, 5),
                    ],
                ),
                _base.row(
                    "By device",
                    [
                        _base.grid_item(p_trap_dev, 0, 0, 12, 10),
                        _base.grid_item(p_sys_dev, 12, 0, 12, 10),
                    ],
                ),
            ],
        ),
        _base.tab(
            "Traps",
            [
                _base.row(
                    "Types & flaps",
                    [
                        _base.grid_item(p_trap_types, 0, 0, 8, 10),
                        _base.grid_item(p_link, 8, 0, 16, 10),
                    ],
                ),
                _base.row("Recent", [_base.grid_item(p_recent_traps, 0, 0, 24, 12)]),
            ],
        ),
        _base.tab(
            "Syslog",
            [
                _base.row("Severity", [_base.grid_item(p_sev, 0, 0, 24, 10)]),
                _base.row("Recent", [_base.grid_item(p_recent_sys, 0, 0, 24, 12)]),
            ],
        ),
        _base.tab(
            "Noise",
            [_base.row("Chatter", [_base.grid_item(p_noisy, 0, 0, 24, 12)])],
        ),
    ]

    return dashboard(
        "ktranslate-network-events",
        "08. Network Events",
        "Fleet event noise: SNMP traps, device syslog, link-flap traps, and noisy devices. "
        "Uses Loki (ktranslate tee_logs). Companion to Device Summary Events tab.",
        els,
        tabs,
        loki=True,
    )


def build_environment() -> dict:
    els: dict[str, dict] = {}
    pid = 900
    panel = _base.panel
    labels_table_transforms = _base.labels_table_transforms

    def add(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel(pid, title, viz, expr, **kw)
        return key

    p_hot = add(
        "stat",
        "Hottest device (°C)",
        f"max(kentik_snmp_Temperature{{{SEL}}}) OR vector(0)",
        field_defaults={"unit": "celsius"},
    )
    p_temp_bar = add(
        "bargauge",
        "Max temperature by device",
        f"sort_desc(max by(device_name) (kentik_snmp_Temperature{{{SEL}}}))",
        legend="{{device_name}}",
        field_defaults={
            "unit": "celsius",
            "thresholds": {
                "mode": "absolute",
                "steps": [
                    {"value": 0, "color": "green"},
                    {"value": 50, "color": "yellow"},
                    {"value": 70, "color": "red"},
                ],
            },
        },
    )
    p_temp_ts = add(
        "timeseries",
        "Temperature over time",
        f"max by(device_name) (kentik_snmp_Temperature{{{SEL}}})",
        legend="{{device_name}}",
        field_defaults={"unit": "celsius"},
    )
    p_fans = add(
        "stat",
        "Non-OK fans",
        f"count(kentik_snmp_tmnxPhysChassisFanOperStatus{{{SEL}}} != 2) OR vector(0)",
    )
    p_psu = add(
        "stat",
        "Non-OK PSUs",
        f'count(kentik_snmp_tmnxPhysChassisPMOutputStatus{{{SEL}}} !~ "online|notEquipped") OR vector(0)',
    )
    p_optics = add(
        "table",
        "Optical / DOM sensors",
        f'count by(device_name, entity_name, entity_sensor_type) ({{__name__=~"(?i)kentik_snmp_.*(entSensor|dBm|optical|rxPower|txPower).*",{SEL}}}) OR on() vector(0)',
        description="Portable probe for optical/DOM-style metrics. Empty until profiles export them.",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "entity_name": "Sensor",
                "entity_sensor_type": "Type",
                "__name__": "Metric",
            }
        ),
    )
    p_ups = add(
        "table",
        "UPS / battery metrics",
        f'count by(device_name) ({{__name__=~"(?i)kentik_snmp_.*(ups|battery|runtime|charge).*",{SEL}}}) OR on() vector(0)',
        description="Portable probe for UPS/battery series (APC/Eaton/etc.). Empty on switch-only labs.",
        transforms=labels_table_transforms({"device_name": "Device", "__name__": "Metric"}),
    )
    p_sensor = add(
        "table",
        "ENTITY-SENSOR style values",
        f'{{__name__=~"(?i)kentik_snmp_.*(entSensorValue|Temperature|Humidity|PercentRH).*",{SEL}}}',
        description="Temperature and other environmental sensors when exported.",
        transforms=labels_table_transforms(
            {"device_name": "Device", "__name__": "Metric", "Value": "Value", "tags_snmp_group": "Group"}
        ),
    )

    tabs = [
        _base.tab(
            "Thermal",
            [
                _base.row(
                    "Heat",
                    [
                        _base.grid_item(p_hot, 0, 0, 6, 5),
                        _base.grid_item(p_fans, 6, 0, 6, 5),
                        _base.grid_item(p_psu, 12, 0, 6, 5),
                    ],
                ),
                _base.row(
                    "By device",
                    [
                        _base.grid_item(p_temp_bar, 0, 0, 10, 10),
                        _base.grid_item(p_temp_ts, 10, 0, 14, 10),
                    ],
                ),
            ],
        ),
        _base.tab(
            "Sensors",
            [_base.row("Environmental sensors", [_base.grid_item(p_sensor, 0, 0, 24, 12)])],
        ),
        _base.tab(
            "Optics",
            [_base.row("DOM / optical", [_base.grid_item(p_optics, 0, 0, 24, 12)])],
        ),
        _base.tab(
            "Power / UPS",
            [_base.row("UPS & battery", [_base.grid_item(p_ups, 0, 0, 24, 12)])],
        ),
    ]

    return dashboard(
        "ktranslate-network-environment",
        "09. Network Environment",
        "Fleet environment: thermal, fans/PSU, optical/DOM and UPS probes when profiles export them.",
        els,
        tabs,
    )


def build_adjacency() -> dict:
    els: dict[str, dict] = {}
    pid = 1000
    panel = _base.panel
    labels_table_transforms = _base.labels_table_transforms

    def add(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel(pid, title, viz, expr, **kw)
        return key

    p_bgp_up = add(
        "stat",
        "BGP established",
        f'count(kentik_snmp_tBgpPeerNgConnState{{{SEL}}} == 6) OR count(kentik_snmp_tBgpPeerNgConnState{{{SEL},tBgpPeerNgConnState="established"}}) OR vector(0)',
    )
    p_bgp_down = add(
        "stat",
        "BGP not established",
        f'count(kentik_snmp_tBgpPeerNgConnState{{{SEL},tBgpPeerNgConnState!="established"}}) OR vector(0)',
    )
    p_bgp_pct = add(
        "bargauge",
        "BGP established % by device",
        f"sort_desc(100 * count by(device_name) (kentik_snmp_tBgpPeerNgConnState{{{SEL}}} == 6) "
        f"/ count by(device_name) (kentik_snmp_tBgpPeerNgConnState{{{SEL}}}))",
        legend="{{device_name}}",
        field_defaults={"unit": "percent", "max": 100},
    )
    p_bgp_bad = add(
        "table",
        "BGP peers not established",
        f'kentik_snmp_tBgpPeerNgConnState{{{SEL},tBgpPeerNgConnState!="established"}}',
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "tBgpPeerNgConnState": "State",
                "tags_snmp_group": "SNMP group",
            }
        ),
    )
    p_flaps = add(
        "timeseries",
        "BGP flaps (range)",
        f"topk(10, sum by(device_name) (increase(kentik_snmp_tBgpPeerNgOperFlaps{{{SEL}}}[$__range])))",
        legend="{{device_name}}",
    )
    p_ospf = add(
        "table",
        "OSPF neighbors (portable)",
        f'count by(device_name) ({{__name__=~"(?i)kentik_snmp_.*(ospf|OSPF).*",{SEL}}}) OR on() vector(0)',
        description="Lights when OSPF neighbor/state metrics exist.",
        transforms=labels_table_transforms({"device_name": "Device", "__name__": "Metric"}),
    )
    p_lldp = add(
        "table",
        "LLDP remotes (portable)",
        f'count by(device_name) ({{__name__=~"(?i)kentik_snmp_.*(lldp|LLDP).*",{SEL}}}) OR on() vector(0)',
        description="SNMP LLDP tables when polled; gnmic LLDP may live under other metric names.",
        transforms=labels_table_transforms({"device_name": "Device", "__name__": "Metric"}),
    )
    p_hsrp = add(
        "table",
        "HSRP / VRRP / stack HA (portable)",
        f'count by(device_name) ({{__name__=~"(?i)kentik_snmp_.*(hsrp|vrrp|stack|virtual.?chassis|csw).*",{SEL}}}) OR on() vector(0)',
        transforms=labels_table_transforms({"device_name": "Device", "__name__": "Metric"}),
    )
    p_wlan = add(
        "table",
        "Wireless / AP / clients (portable)",
        f'count by(device_name) ({{__name__=~"(?i)kentik_snmp_.*(wlan|wireless|aire|unifi|fortiap|wlsx).*",{SEL}}}) OR on() vector(0)',
        description="AP/client metrics when wireless profiles are polled.",
        transforms=labels_table_transforms({"device_name": "Device", "__name__": "Metric"}),
    )
    p_pfx = add(
        "table",
        "BGP prefix counts",
        f"max by(device_name, tags_snmp_group) (kentik_snmp_tBgpPeerNgOperActivePrefixes{{{SEL}}})",
        transforms=labels_table_transforms(
            {"device_name": "Device", "tags_snmp_group": "Group", "Value": "Active prefixes"}
        ),
    )

    tabs = [
        _base.tab(
            "BGP",
            [
                _base.row(
                    "Session health",
                    [
                        _base.grid_item(p_bgp_up, 0, 0, 6, 5),
                        _base.grid_item(p_bgp_down, 6, 0, 6, 5),
                        _base.grid_item(p_bgp_pct, 12, 0, 12, 8),
                    ],
                ),
                _base.row(
                    "Detail",
                    [
                        _base.grid_item(p_bgp_bad, 0, 0, 12, 10),
                        _base.grid_item(p_flaps, 12, 0, 12, 10),
                    ],
                ),
                _base.row("Prefixes", [_base.grid_item(p_pfx, 0, 0, 24, 8)]),
            ],
        ),
        _base.tab(
            "IGP / LLDP",
            [
                _base.row(
                    "OSPF & LLDP",
                    [
                        _base.grid_item(p_ospf, 0, 0, 12, 10),
                        _base.grid_item(p_lldp, 12, 0, 12, 10),
                    ],
                ),
            ],
        ),
        _base.tab(
            "HA / stack",
            [_base.row("Redundancy", [_base.grid_item(p_hsrp, 0, 0, 24, 10)])],
        ),
        _base.tab(
            "Wireless",
            [_base.row("AP / clients", [_base.grid_item(p_wlan, 0, 0, 24, 10)])],
        ),
    ]

    return dashboard(
        "ktranslate-network-adjacency",
        "10. Network Adjacency",
        "Control-plane and adjacency: BGP (lab-ready), plus portable OSPF/LLDP/HA/wireless panels.",
        els,
        tabs,
    )


BOARDS = [
    ("08 Network Events.json", build_events),
    ("09 Network Environment.json", build_environment),
    ("10 Network Adjacency.json", build_adjacency),
]


def push_one(dash: dict) -> None:
    load_env()
    namespace = _base.ns()
    name = dash["metadata"]["name"]
    body = copy.deepcopy(dash)
    body["metadata"]["namespace"] = namespace
    get_path = f"/apis/dashboard.grafana.app/v2/namespaces/{namespace}/dashboards/{name}"
    status, existing = _base.api("GET", get_path)
    if status == 200:
        body["metadata"]["resourceVersion"] = existing["metadata"]["resourceVersion"]
        for k in ("generation", "creationTimestamp", "uid", "managedFields"):
            body["metadata"].pop(k, None)
        body.pop("status", None)
        status, data = _base.api("PUT", get_path, body)
        print(f"PUT {name} -> {status} gen={(data or {}).get('metadata', {}).get('generation')}")
    else:
        status, data = _base.api(
            "POST", f"/apis/dashboard.grafana.app/v2/namespaces/{namespace}/dashboards", body
        )
        print(f"POST {name} -> {status} gen={(data or {}).get('metadata', {}).get('generation')}")
    if status not in (200, 201):
        raise SystemExit(data)
    _, after = _base.api("GET", get_path)
    kind = ((after or {}).get("spec") or {}).get("layout", {}).get("kind")
    print(f"  verify layout={kind}")
    if kind != "TabsLayout":
        raise SystemExit(f"layout degraded: {kind}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--push", action="store_true")
    args = ap.parse_args()
    DASH_DIR.mkdir(parents=True, exist_ok=True)
    for filename, builder in BOARDS:
        dash = builder()
        path = DASH_DIR / filename
        path.write_text(json.dumps(dash, indent=2) + "\n", encoding="utf-8")
        print(f"wrote {path} ({dash['spec']['title']})")
        if args.push:
            push_one(dash)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
