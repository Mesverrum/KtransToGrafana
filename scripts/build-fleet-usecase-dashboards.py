#!/usr/bin/env python3
"""Build KtransToGrafana fleet use-case dashboards 05–07 (v2 TabsLayout).

Writes JSON under dashboards/ and optionally POSTs/PUTs to Grafana Cloud.

Usage:
  python3 scripts/build-fleet-usecase-dashboards.py
  python3 scripts/build-fleet-usecase-dashboards.py --push
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
DASH_DIR = REPO / "dashboards"
VIZ = "13.2.0-31575599388"
DS = {"name": "$datasource"}
SEL = 'tags_snmp_group=~"$snmp_group",provider=~"$provider",device_name=~"$device_name"'
def load_env() -> None:
    candidates = [
        REPO / ".env",
        REPO.parent / "network-o11y-demo" / "local" / ".env",
        Path.home() / "projects" / "network-o11y-demo" / "local" / ".env",
    ]
    for env_file in candidates:
        if not env_file.is_file():
            continue
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
        if os.environ.get("GRAFANA_URL") and os.environ.get("GRAFANA_TOKEN"):
            return


def api(method: str, path: str, body: Any | None = None) -> tuple[int, Any]:
    base = os.environ["GRAFANA_URL"].rstrip("/")
    token = os.environ["GRAFANA_TOKEN"]
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
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
        with urllib.request.urlopen(req, context=ssl.create_default_context(), timeout=180) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:3000]}


def ns() -> str:
    if os.environ.get("GRAFANA_DASHBOARD_NAMESPACE"):
        return os.environ["GRAFANA_DASHBOARD_NAMESPACE"].strip()
    return f"stacks-{os.environ.get('GC_OTLP_ACCOUNT', '').strip()}"


def fleet_vars() -> list[dict]:
    return [
        {
            "kind": "DatasourceVariable",
            "spec": {
                "name": "datasource",
                "pluginId": "prometheus",
                "refresh": "onDashboardLoad",
                "regex": "",
                "current": {"text": "default", "value": "default"},
                "options": [],
                "multi": False,
                "includeAll": False,
                "label": "Prometheus data source",
                "hide": "dontHide",
                "skipUrlSync": False,
                "allowCustomValue": True,
            },
        },
        {
            "kind": "QueryVariable",
            "spec": {
                "name": "snmp_group",
                "current": {"text": "All", "value": ["$__all"]},
                "label": "SNMP group",
                "hide": "dontHide",
                "refresh": "onTimeRangeChanged",
                "skipUrlSync": False,
                "query": {
                    "kind": "DataQuery",
                    "group": "prometheus",
                    "version": "v0",
                    "datasource": DS,
                    "spec": {
                        "qryType": 1,
                        "query": "label_values(kentik_snmp_PollingHealth,tags_snmp_group)",
                        "refId": "A",
                    },
                },
                "regex": "",
                "regexApplyTo": "value",
                "sort": "alphabeticalAsc",
                "options": [],
                "multi": True,
                "includeAll": True,
                "allValue": ".*",
                "allowCustomValue": True,
            },
        },
        {
            "kind": "QueryVariable",
            "spec": {
                "name": "provider",
                "current": {"text": "All", "value": ["$__all"]},
                "label": "Provider",
                "hide": "dontHide",
                "refresh": "onTimeRangeChanged",
                "skipUrlSync": False,
                "query": {
                    "kind": "DataQuery",
                    "group": "prometheus",
                    "version": "v0",
                    "datasource": DS,
                    "spec": {
                        "qryType": 1,
                        "query": "label_values(kentik_snmp_Uptime,provider)",
                        "refId": "A",
                    },
                },
                "regex": "",
                "regexApplyTo": "value",
                "sort": "alphabeticalAsc",
                "options": [],
                "multi": True,
                "includeAll": True,
                "allValue": ".*",
                "allowCustomValue": True,
            },
        },
        {
            "kind": "QueryVariable",
            "spec": {
                "name": "device_name",
                "current": {"text": "All", "value": ["$__all"]},
                "label": "Device",
                "hide": "dontHide",
                "refresh": "onTimeRangeChanged",
                "skipUrlSync": False,
                "query": {
                    "kind": "DataQuery",
                    "group": "prometheus",
                    "version": "v0",
                    "datasource": DS,
                    "spec": {
                        "qryType": 1,
                        "query": f'label_values(kentik_snmp_PollingHealth{{{SEL}}},device_name)',
                        "refId": "A",
                    },
                },
                "regex": "",
                "regexApplyTo": "value",
                "sort": "alphabeticalAsc",
                "options": [],
                "multi": True,
                "includeAll": True,
                "allValue": ".*",
                "allowCustomValue": True,
            },
        },
    ]


def prom_query(expr: str, *, instant: bool = True, legend: str = "__auto") -> dict:
    return {
        "kind": "PanelQuery",
        "spec": {
            "query": {
                "kind": "DataQuery",
                "group": "prometheus",
                "version": "v0",
                "datasource": DS,
                "spec": {
                    "expr": expr,
                    "instant": instant,
                    "range": not instant,
                    "legendFormat": legend,
                },
            },
            "refId": "A",
            "hidden": False,
        },
    }


def panel(
    pid: int,
    title: str,
    viz: str,
    expr: str,
    *,
    description: str = "",
    instant: bool = True,
    legend: str = "__auto",
    transforms: list | None = None,
    options: dict | None = None,
    field_defaults: dict | None = None,
    links: list | None = None,
) -> dict:
    opts = options or {}
    defaults = field_defaults or {}
    if viz == "stat":
        viz_opts = {
            "colorMode": "value",
            "graphMode": "none",
            "justifyMode": "auto",
            "orientation": "auto",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "textMode": "auto",
            **opts,
        }
        if "unit" not in defaults:
            defaults.setdefault("unit", "short")
    elif viz == "piechart":
        viz_opts = {
            "legend": {"displayMode": "list", "placement": "right", "showLegend": True},
            "pieType": "pie",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "tooltip": {"mode": "single", "sort": "none"},
            **opts,
        }
    elif viz == "barchart":
        viz_opts = {
            "legend": {"displayMode": "list", "placement": "bottom", "showLegend": False},
            "orientation": "horizontal",
            "xTickLabelRotation": 0,
            "xTickLabelSpacing": 0,
            **opts,
        }
    elif viz == "timeseries":
        viz_opts = {
            "legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
            **opts,
        }
        instant = False
    elif viz == "table":
        viz_opts = {"showHeader": True, "cellHeight": "sm", "footer": {"show": False}, **opts}
    elif viz == "bargauge":
        viz_opts = {
            "displayMode": "gradient",
            "orientation": "horizontal",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "showUnfilled": True,
            **opts,
        }
    else:
        viz_opts = opts

    return {
        "kind": "Panel",
        "spec": {
            "id": pid,
            "title": title,
            "description": description,
            "links": links or [],
            "data": {
                "kind": "QueryGroup",
                "spec": {
                    "queries": [prom_query(expr, instant=instant, legend=legend)],
                    "transformations": transforms or [],
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


def labels_table_transforms(rename: dict[str, str], hide: list[str] | None = None) -> list:
    hide = hide or [
        "Time",
        "__name__",
        "deployment_host",
        "job",
        "service_name",
        "src_addr",
        "instrumentation_name",
        "Value",
    ]
    return [
        {"kind": "labelsToFields", "spec": {"id": "labelsToFields", "disabled": False}},
        {"kind": "merge", "spec": {"id": "merge", "disabled": False}},
        {
            "kind": "organize",
            "spec": {
                "id": "organize",
                "disabled": False,
                "options": {
                    "excludeByName": {h: True for h in hide},
                    "renameByName": rename,
                    "indexByName": {},
                },
            },
        },
    ]


def grid_item(name: str, x: int, y: int, w: int, h: int) -> dict:
    return {
        "kind": "GridLayoutItem",
        "spec": {
            "x": x,
            "y": y,
            "width": w,
            "height": h,
            "element": {"kind": "ElementReference", "name": name},
        },
    }


def row(title: str, items: list[dict], *, collapse: bool = False) -> dict:
    return {
        "kind": "RowsLayoutRow",
        "spec": {
            "title": title,
            "collapse": collapse,
            "hideHeader": False,
            "fillScreen": False,
            "layout": {"kind": "GridLayout", "spec": {"items": items}},
        },
    }


def tab(title: str, rows: list[dict]) -> dict:
    return {
        "kind": "TabsLayoutTab",
        "spec": {
            "title": title,
            "layout": {"kind": "RowsLayout", "spec": {"rows": rows}},
        },
    }


def dashboard(
    uid: str,
    title: str,
    description: str,
    elements: dict[str, dict],
    tabs: list[dict],
) -> dict:
    return {
        "kind": "Dashboard",
        "apiVersion": "dashboard.grafana.app/v2",
        "metadata": {
            "name": uid,
            "annotations": {"grafana.app/folder": "network-lab"},
        },
        "spec": {
            "title": title,
            "description": description,
            "editable": True,
            "preload": False,
            "liveNow": False,
            "cursorSync": "Off",
            "tags": ["ktranslate", "fleet", "network-lab"],
            "timeSettings": {
                "from": "now-6h",
                "to": "now",
                "timezone": "browser",
                "autoRefresh": "1m",
                "autoRefreshIntervals": ["30s", "1m", "5m", "15m"],
                "fiscalYearStartMonth": 0,
                "hideTimeSettings": False,
            },
            "links": [
                {
                    "title": "Network Dashboards",
                    "type": "dashboards",
                    "icon": "external link",
                    "tooltip": "",
                    "url": "",
                    "tags": ["ktranslate"],
                    "asDropdown": True,
                    "targetBlank": True,
                    "includeVars": True,
                    "keepTime": True,
                }
            ],
            "annotations": [],
            "variables": fleet_vars(),
            "elements": elements,
            "layout": {"kind": "TabsLayout", "spec": {"tabs": tabs}},
        },
    }


def build_inventory() -> dict:
    els: dict[str, dict] = {}
    pid = 500

    def add(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel(pid, title, viz, expr, **kw)
        return key

    # Overview stats
    p_dev = add(
        "stat",
        "Devices",
        f"count(count by(device_name) (kentik_snmp_PollingHealth{{{SEL}}})) OR vector(0)",
        description="Unique devices reporting SNMP polling health.",
    )
    p_models = add(
        "stat",
        "Distinct models",
        f"count(count by(tags_kentik_model) (kentik_snmp_CPU{{{SEL}}})) OR vector(0)",
        description="Distinct tags_kentik_model values across reporting devices.",
    )
    p_prov = add(
        "stat",
        "Distinct providers",
        f"count(count by(provider) (kentik_snmp_CPU{{{SEL}}})) OR vector(0)",
    )
    p_groups = add(
        "stat",
        "SNMP groups",
        f"count(count by(tags_snmp_group) (kentik_snmp_CPU{{{SEL}}})) OR vector(0)",
    )
    p_d24 = add(
        "stat",
        "Devices Δ 24h",
        f"(count(count by(device_name) (kentik_snmp_PollingHealth{{{SEL}}})) OR vector(0))"
        f" - (count(count by(device_name) (kentik_snmp_PollingHealth{{{SEL}}} offset 24h)) OR vector(0))",
        description="Change in reporting device count vs 24h ago.",
        instant=False,
        field_defaults={"unit": "short"},
    )
    p_pie_model = add(
        "piechart",
        "Devices by model",
        f"count by(tags_kentik_model) (kentik_snmp_CPU{{{SEL}}})",
        legend="{{tags_kentik_model}}",
    )
    p_pie_group = add(
        "piechart",
        "Devices by SNMP group",
        f"count by(tags_snmp_group) (kentik_snmp_CPU{{{SEL}}})",
        legend="{{tags_snmp_group}}",
    )
    p_bar_prov = add(
        "barchart",
        "Devices by provider",
        f"count by(provider) (kentik_snmp_CPU{{{SEL}}})",
        legend="{{provider}}",
    )

    # Devices table — join via multiple queries is hard; use CPU as census + labels
    p_dev_tbl = add(
        "table",
        "Device inventory",
        f"max by(device_name, tags_kentik_model, provider, tags_snmp_group) (kentik_snmp_CPU{{{SEL}}})",
        description="One row per device from kentik_snmp_CPU labels. Click through to Device Details.",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "tags_kentik_model": "Model",
                "provider": "Provider",
                "tags_snmp_group": "SNMP group",
            }
        ),
    )
    p_uptime = add(
        "table",
        "Uptime by device",
        f"max by(device_name, tags_snmp_group) (kentik_snmp_Uptime{{{SEL}}})",
        description="SNMP sysUpTime-style uptime (seconds) when exported.",
        transforms=labels_table_transforms(
            {"device_name": "Device", "tags_snmp_group": "SNMP group", "Value": "Uptime"},
            hide=["Time", "__name__", "deployment_host", "job", "service_name", "src_addr", "provider"],
        ),
        field_defaults={"unit": "s"},
    )
    p_health = add(
        "table",
        "Polling health",
        f"max by(device_name, tags_snmp_group) (kentik_snmp_PollingHealth{{{SEL}}})",
        description="1 = Healthy. Non-1 means the poller is struggling for that device.",
        transforms=labels_table_transforms(
            {"device_name": "Device", "tags_snmp_group": "SNMP group", "Value": "Health"},
        ),
    )

    # Hardware serials
    p_serial = add(
        "table",
        "Hardware serials (chassis / FRU)",
        f'kentik_snmp_tmnxHwOperState{{{SEL},hw_serial!="",hw_serial!="N/A"}}',
        description="Nokia TIMETRA hw_serial tags (and similar when present). Lab simulators often show placeholder serials.",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "hw_name": "Name",
                "hw_class": "Class",
                "hw_serial": "Serial",
                "tmnxHwOperState": "Oper state",
                "tags_snmp_group": "SNMP group",
            }
        ),
    )

    # Firmware — portable; may be empty on SRL-only labs
    p_fw = add(
        "table",
        "Firmware / software versions",
        f'count by(device_name, tags_kentik_model) ({{__name__=~"(?i)kentik_snmp_.*(firmware|software.?version|sysDescr|sysdescr).*",{SEL}}}) OR on() vector(0)',
        description=(
            "Portable probe for firmware/software/sysDescr-style metrics from snmp-profiles. "
            "Empty on estates that only export model tags (e.g. current SRL lab) — use Devices + model instead."
        ),
        transforms=labels_table_transforms(
            {"device_name": "Device", "tags_kentik_model": "Model", "__name__": "Metric"},
        ),
    )
    p_fw_note = add(
        "stat",
        "Firmware series present",
        f'count({{__name__=~"(?i)kentik_snmp_.*(firmware|software.?version|sysDescr).*",{SEL}}}) OR vector(0)',
        description="Non-zero when firmware-like series exist for the current filters.",
    )

    tabs = [
        tab(
            "Overview",
            [
                row(
                    "Census",
                    [
                        grid_item(p_dev, 0, 0, 6, 5),
                        grid_item(p_models, 6, 0, 6, 5),
                        grid_item(p_prov, 12, 0, 6, 5),
                        grid_item(p_groups, 18, 0, 6, 5),
                        grid_item(p_d24, 0, 5, 6, 4),
                        grid_item(p_fw_note, 6, 5, 6, 4),
                    ],
                ),
                row(
                    "Breakdown",
                    [
                        grid_item(p_pie_model, 0, 0, 8, 10),
                        grid_item(p_pie_group, 8, 0, 8, 10),
                        grid_item(p_bar_prov, 16, 0, 8, 10),
                    ],
                ),
            ],
        ),
        tab(
            "Devices",
            [
                row("Inventory", [grid_item(p_dev_tbl, 0, 0, 24, 12)]),
                row(
                    "Uptime & health",
                    [
                        grid_item(p_uptime, 0, 0, 12, 10),
                        grid_item(p_health, 12, 0, 12, 10),
                    ],
                ),
            ],
        ),
        tab(
            "Hardware serials",
            [row("Chassis / FRU serials", [grid_item(p_serial, 0, 0, 24, 14)])],
        ),
        tab(
            "Firmware",
            [row("Software / firmware", [grid_item(p_fw, 0, 0, 24, 12)])],
        ),
    ]

    return dashboard(
        "ktranslate-network-inventory",
        "05. Network Inventory",
        "Fleet inventory: models, providers, SNMP groups, serials, and firmware when profiles export it. "
        "Companion to Device Summary — drill to Device Details.",
        els,
        tabs,
    )


def build_risk() -> dict:
    els: dict[str, dict] = {}
    pid = 600

    def add(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel(pid, title, viz, expr, **kw)
        return key

    p_unhealthy = add(
        "stat",
        "Unhealthy pollers",
        f"count(kentik_snmp_PollingHealth{{{SEL}}} != 1) OR vector(0)",
        description="Devices where PollingHealth is not Healthy (1).",
        field_defaults={"thresholds": {"mode": "absolute", "steps": [{"value": 0, "color": "green"}, {"value": 1, "color": "red"}]}},
    )
    p_hw_dev = add(
        "stat",
        "Devices with hardware issues",
        f"count(count by(device_name) (kentik_snmp_tmnxHwOperState{{{SEL}}} != 2)) OR vector(0)",
        description="Devices with any TIMETRA chassis component not inService (2).",
    )
    p_fans = add(
        "stat",
        "Non-OK fans",
        f"count(kentik_snmp_tmnxPhysChassisFanOperStatus{{{SEL}}} != 2) OR vector(0)",
    )
    p_psu = add(
        "stat",
        "Non-OK power supplies",
        f'count(kentik_snmp_tmnxPhysChassisPMOutputStatus{{{SEL}}} !~ "online|notEquipped") OR vector(0)',
    )
    p_if_down = add(
        "stat",
        "Interfaces down (admin-up)",
        f'count(kentik_snmp_if_OperStatus{{{SEL},if_AdminStatus!="down"}} != 1) OR vector(0)',
    )
    p_bgp_bad = add(
        "stat",
        "BGP peers not established",
        f'count(kentik_snmp_tBgpPeerNgConnState{{{SEL},tBgpPeerNgConnState!="established"}}) OR vector(0)',
    )

    p_hw_tbl = add(
        "table",
        "Non-inService hardware components",
        f'kentik_snmp_tmnxHwOperState{{{SEL},tmnxHwOperState=~"failed|outOfService|diagnosing|resetPending|booting"}}',
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "hw_name": "Name",
                "hw_class": "Class",
                "tmnxHwOperState": "State",
                "tags_snmp_group": "SNMP group",
            }
        ),
    )
    p_fan_tbl = add(
        "table",
        "Fan issues",
        f"kentik_snmp_tmnxPhysChassisFanOperStatus{{{SEL}}} != 2",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "tmnxPhysChassisFanOperStatus": "Fan state",
                "tags_snmp_group": "SNMP group",
            }
        ),
    )
    p_err = add(
        "table",
        "Top interface errors",
        f"topk(20, sum by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_ifInErrors{{{SEL}}} / 60) + sum by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_ifOutErrors{{{SEL}}} / 60))",
        description="In+out errors/s (ktranslate delta gauges / 60s poll).",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "if_interface_name": "Interface",
                "tags_snmp_group": "SNMP group",
                "Value": "Errors/s",
            }
        ),
    )
    p_disc = add(
        "table",
        "Top interface discards",
        f"topk(20, sum by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_ifInDiscards{{{SEL}}} / 60) + sum by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_ifOutDiscards{{{SEL}}} / 60))",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "if_interface_name": "Interface",
                "tags_snmp_group": "SNMP group",
                "Value": "Discards/s",
            }
        ),
    )
    p_bgp = add(
        "table",
        "BGP sessions not established",
        f'kentik_snmp_tBgpPeerNgConnState{{{SEL},tBgpPeerNgConnState!="established"}}',
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "tBgpPeerNgConnState": "State",
                "tags_snmp_group": "SNMP group",
            }
        ),
    )
    p_down_dev = add(
        "bargauge",
        "Interfaces down by device",
        f'count by(device_name) (kentik_snmp_if_OperStatus{{{SEL},if_AdminStatus!="down"}} != 1)',
        legend="{{device_name}}",
    )
    p_temp = add(
        "bargauge",
        "Max temperature by device",
        f"max by(device_name) (kentik_snmp_Temperature{{{SEL}}})",
        legend="{{device_name}}",
        field_defaults={"unit": "celsius"},
    )

    tabs = [
        tab(
            "Overview",
            [
                row(
                    "Risk scores",
                    [
                        grid_item(p_unhealthy, 0, 0, 4, 5),
                        grid_item(p_hw_dev, 4, 0, 4, 5),
                        grid_item(p_fans, 8, 0, 4, 5),
                        grid_item(p_psu, 12, 0, 4, 5),
                        grid_item(p_if_down, 16, 0, 4, 5),
                        grid_item(p_bgp_bad, 20, 0, 4, 5),
                    ],
                ),
                row(
                    "Hotspots",
                    [
                        grid_item(p_down_dev, 0, 0, 12, 10),
                        grid_item(p_temp, 12, 0, 12, 10),
                    ],
                ),
            ],
        ),
        tab(
            "Hardware",
            [
                row("Components", [grid_item(p_hw_tbl, 0, 0, 24, 10)]),
                row("Fans", [grid_item(p_fan_tbl, 0, 0, 24, 8)]),
            ],
        ),
        tab(
            "Interfaces",
            [
                row(
                    "Errors & discards",
                    [
                        grid_item(p_err, 0, 0, 12, 12),
                        grid_item(p_disc, 12, 0, 12, 12),
                    ],
                ),
            ],
        ),
        tab(
            "Adjacency",
            [row("BGP", [grid_item(p_bgp, 0, 0, 24, 12)])],
        ),
    ]

    return dashboard(
        "ktranslate-network-risk",
        "06. Network Risk",
        "Fleet risk: hardware faults, interface errors/discards, BGP not-established, unhealthy pollers. "
        "Companion to Device Summary — drill to Device Details.",
        els,
        tabs,
    )


def build_capacity() -> dict:
    els: dict[str, dict] = {}
    pid = 700

    def add(viz: str, title: str, expr: str, **kw: Any) -> str:
        nonlocal pid
        pid += 1
        key = f"panel-{pid}"
        els[key] = panel(pid, title, viz, expr, **kw)
        return key

    p_cpu_avg = add(
        "stat",
        "Avg fleet CPU",
        f"avg(max by(device_name) (kentik_snmp_CPU{{{SEL}}})) OR vector(0)",
        field_defaults={"unit": "percent"},
    )
    p_mem_avg = add(
        "stat",
        "Avg fleet memory",
        f"avg(max by(device_name) (kentik_snmp_MemoryUtilization{{{SEL}}})) OR vector(0)",
        field_defaults={"unit": "percent"},
    )
    p_traf = add(
        "stat",
        "Total fleet traffic",
        f"sum(kentik_snmp_ifHCInOctets{{{SEL}}} * 8 / 60) + sum(kentik_snmp_ifHCOutOctets{{{SEL}}} * 8 / 60)",
        description="Sum in+out bps (ktranslate delta gauges × 8 / 60).",
        field_defaults={"unit": "bps"},
        instant=False,
    )
    p_wan = add(
        "stat",
        "WAN traffic",
        f'sum(kentik_snmp_ifHCInOctets{{{SEL},if_Alias=~".*WAN.*"}} * 8 / 60) '
        f'+ sum(kentik_snmp_ifHCOutOctets{{{SEL},if_Alias=~".*WAN.*"}} * 8 / 60)',
        description="Interfaces with ifAlias matching .*WAN.*.",
        field_defaults={"unit": "bps"},
        instant=False,
    )

    p_cpu_bar = add(
        "bargauge",
        "CPU by device",
        f"sort_desc(max by(device_name) (kentik_snmp_CPU{{{SEL}}}))",
        legend="{{device_name}}",
        field_defaults={
            "unit": "percent",
            "max": 100,
            "thresholds": {
                "mode": "absolute",
                "steps": [
                    {"value": 0, "color": "green"},
                    {"value": 70, "color": "yellow"},
                    {"value": 90, "color": "red"},
                ],
            },
        },
    )
    p_mem_bar = add(
        "bargauge",
        "Memory by device",
        f"sort_desc(max by(device_name) (kentik_snmp_MemoryUtilization{{{SEL}}}))",
        legend="{{device_name}}",
        field_defaults={
            "unit": "percent",
            "max": 100,
            "thresholds": {
                "mode": "absolute",
                "steps": [
                    {"value": 0, "color": "green"},
                    {"value": 70, "color": "yellow"},
                    {"value": 90, "color": "red"},
                ],
            },
        },
    )
    p_cpu_ts = add(
        "timeseries",
        "CPU — top 10 devices",
        f"topk(10, max by(device_name) (kentik_snmp_CPU{{{SEL}}}))",
        legend="{{device_name}}",
        field_defaults={"unit": "percent"},
    )
    p_mem_ts = add(
        "timeseries",
        "Memory — top 10 devices",
        f"topk(10, max by(device_name) (kentik_snmp_MemoryUtilization{{{SEL}}}))",
        legend="{{device_name}}",
        field_defaults={"unit": "percent"},
    )
    p_util = add(
        "table",
        "Top interface utilization",
        f"topk(20, max by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_IfInUtilization{{{SEL}}}) or max by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_IfOutUtilization{{{SEL}}}))",
        description="Uses IfIn/OutUtilization when present.",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "if_interface_name": "Interface",
                "tags_snmp_group": "SNMP group",
                "Value": "Util %",
            }
        ),
        field_defaults={"unit": "percent"},
    )
    p_bps = add(
        "table",
        "Top interface throughput",
        f"topk(20, sum by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_ifHCInOctets{{{SEL}}} * 8 / 60) + sum by(device_name, if_interface_name, tags_snmp_group) "
        f"(kentik_snmp_ifHCOutOctets{{{SEL}}} * 8 / 60))",
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "if_interface_name": "Interface",
                "tags_snmp_group": "SNMP group",
                "Value": "bps",
            }
        ),
        field_defaults={"unit": "bps"},
    )
    p_wan_ts = add(
        "timeseries",
        "WAN traffic over time",
        f'sum by(device_name, if_Alias) (kentik_snmp_ifHCInOctets{{{SEL},if_Alias=~".*WAN.*"}} * 8 / 60) '
        f'+ sum by(device_name, if_Alias) (kentik_snmp_ifHCOutOctets{{{SEL},if_Alias=~".*WAN.*"}} * 8 / 60)',
        legend="{{device_name}} {{if_Alias}}",
        field_defaults={"unit": "bps"},
    )
    p_wan_tbl = add(
        "table",
        "WAN interfaces",
        f'topk(20, sum by(device_name, if_interface_name, if_Alias, tags_snmp_group) '
        f'(kentik_snmp_ifHCInOctets{{{SEL},if_Alias=~".*WAN.*"}} * 8 / 60) + '
        f'sum by(device_name, if_interface_name, if_Alias, tags_snmp_group) '
        f'(kentik_snmp_ifHCOutOctets{{{SEL},if_Alias=~".*WAN.*"}} * 8 / 60))',
        transforms=labels_table_transforms(
            {
                "device_name": "Device",
                "if_interface_name": "Interface",
                "if_Alias": "Alias",
                "tags_snmp_group": "SNMP group",
                "Value": "bps",
            }
        ),
        field_defaults={"unit": "bps"},
    )
    p_stack = add(
        "timeseries",
        "Fleet traffic by device",
        f"sum by(device_name) (kentik_snmp_ifHCInOctets{{{SEL}}} * 8 / 60) "
        f"+ sum by(device_name) (kentik_snmp_ifHCOutOctets{{{SEL}}} * 8 / 60)",
        legend="{{device_name}}",
        field_defaults={"unit": "bps"},
    )

    tabs = [
        tab(
            "Overview",
            [
                row(
                    "Capacity scores",
                    [
                        grid_item(p_cpu_avg, 0, 0, 6, 5),
                        grid_item(p_mem_avg, 6, 0, 6, 5),
                        grid_item(p_traf, 12, 0, 6, 5),
                        grid_item(p_wan, 18, 0, 6, 5),
                    ],
                ),
                row(
                    "CPU & memory",
                    [
                        grid_item(p_cpu_bar, 0, 0, 12, 10),
                        grid_item(p_mem_bar, 12, 0, 12, 10),
                    ],
                ),
            ],
        ),
        tab(
            "Compute",
            [
                row(
                    "Trends",
                    [
                        grid_item(p_cpu_ts, 0, 0, 12, 10),
                        grid_item(p_mem_ts, 12, 0, 12, 10),
                    ],
                ),
            ],
        ),
        tab(
            "Interfaces",
            [
                row(
                    "Hot interfaces",
                    [
                        grid_item(p_util, 0, 0, 12, 12),
                        grid_item(p_bps, 12, 0, 12, 12),
                    ],
                ),
                row("Fleet throughput", [grid_item(p_stack, 0, 0, 24, 10)]),
            ],
        ),
        tab(
            "WAN",
            [
                row("WAN uplinks", [grid_item(p_wan_ts, 0, 0, 24, 10)]),
                row("WAN table", [grid_item(p_wan_tbl, 0, 0, 24, 10)]),
            ],
        ),
    ]

    return dashboard(
        "ktranslate-network-capacity",
        "07. Network Capacity",
        "Fleet capacity: CPU, memory, interface utilization/throughput, WAN uplinks (ifAlias ~ WAN). "
        "Companion to Device Summary — drill to Device Details.",
        els,
        tabs,
    )


BOARDS = [
    ("05 Network Inventory.json", build_inventory),
    ("06 Network Risk.json", build_risk),
    ("07 Network Capacity.json", build_capacity),
]


def push_one(dash: dict) -> None:
    load_env()
    namespace = ns()
    name = dash["metadata"]["name"]
    body = copy.deepcopy(dash)
    body["metadata"]["namespace"] = namespace
    get_path = f"/apis/dashboard.grafana.app/v2/namespaces/{namespace}/dashboards/{name}"
    status, existing = api("GET", get_path)
    if status == 200:
        body["metadata"]["resourceVersion"] = existing["metadata"]["resourceVersion"]
        for k in ("generation", "creationTimestamp", "uid", "managedFields"):
            body["metadata"].pop(k, None)
        body.pop("status", None)
        status, data = api("PUT", get_path, body)
        print(f"PUT {name} -> {status} gen={(data or {}).get('metadata', {}).get('generation')}")
    else:
        status, data = api(
            "POST", f"/apis/dashboard.grafana.app/v2/namespaces/{namespace}/dashboards", body
        )
        print(f"POST {name} -> {status} gen={(data or {}).get('metadata', {}).get('generation')}")
    if status not in (200, 201):
        raise SystemExit(data)
    status2, after = api("GET", get_path)
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
