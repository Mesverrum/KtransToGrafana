# Grafana Network Dashboard skills (portable)

Two companion guides for **ktranslate-based Network Device Details** dashboards on **any Grafana Cloud stack**. Use them as Grafana Cloud Assistant skills, operator runbooks, or agent context when importing or extending the ktranslate dashboard set.

| Skill | File | Use when |
|-------|------|----------|
| **Design Patterns** | [Design Patterns](network_dashboard_design.md) | Adding/editing panels, rows, tabs, tables, naming, layout |
| **Expanding for New Hardware** | [Expanding for New Hardware](network_dashboard_new_hardware.md) | Onboarding a new vendor, SNMP profile, or device type |

## Prerequisites (any stack)

- **Collector:** [ktranslate](https://github.com/kentik/ktranslate) exporting OTLP metrics to Grafana Cloud Prometheus
- **Metric prefixes:** `kentik_snmp_*`, `kentik_ping_*`, `network_io_by_flow*` (flows)
- **Dashboard:** Network Device Details style board — **TabsLayout** v2 manifest (not legacy `POST /api/dashboards/db` flattening)
- **Device identity label:** `device_name` on all series (dashboard variable name may differ — see below)

## Variable mapping (after import)

Imported dashboards may name the device selector differently. **Do not hardcode hostnames** in queries.

| Role | Label in PromQL | Common variable names |
|------|-----------------|-------------------------|
| Single device (Device Details) | `device_name` | `$instance`, `$device`, `$device_name` |
| Fleet filter (Device Summary) | `device_name` + often `provider` | `$device_name`, `$provider` |
| Interface drill-down | `if_interface_name` | `$interface_name`, `$interface` |

In these skills, **`$device`** means *your* single-device selector variable. Replace with the name shown in **Dashboard settings → Variables**.

## What is stack-specific vs portable

| Portable (all ktranslate + Grafana Cloud) | Adapt per deployment |
|-------------------------------------------|----------------------|
| TabsLayout / row / grid layout | Dashboard UID, folder, datasource variable |
| `has_*` conditional rows | Exact list of `has_*` vars on your import |
| `labelsToFields → merge → organize` for tables | Column renames per vendor MIB |
| Hide `deployment_host`, `src_addr`, SNMP junk labels | Extra labels your stack adds |
| `kentik_ping_*` vs `kentik_snmp_*` gate metrics | Gate metric per vendor (see expand skill) |
| ktranslate delta-gauge bps (`* 8 / poll_interval`) | Poll interval if not 60s |
| `max by(device_name)` to collapse stale series | Whether you multi-home collectors |

| Not portable — verify on your fleet |
|---------------------------------------|
| BGP/OSPF/HSRP enum numeric mappings (vendor MIB) |
| `has_memory` gate metric (`hrStorageUsedPercent` vs `MemoryUtilization`) |
| Nokia SRL metric names (`tBgpPeerNgConnState`, `tmnxHwOperState`, …) |

## ktranslate PromQL (all stacks)

ktranslate SNMP interface/error metrics are typically **delta gauges** (per poll), not native Prometheus counters:

| Use | Avoid |
|-----|-------|
| `(kentik_snmp_ifHCInOctets{...}) * 8 / 60` for bps @ 60s poll | `rate(kentik_snmp_ifHC*Octets[...])` |
| `(kentik_snmp_ifInErrors{...}) / 60` for errors/s | `rate(kentik_snmp_if*Errors[...])` |
| `kentik_snmp_MemoryUtilization` when profile tags support it | Hand-rolled Used/Available ratios |
| `max_over_time(network_io_by_flow_bytes[...])` for flow rollups | `rate(network_io_by_flow_bytes[...])` |

`rate()` remains appropriate for **true counters** (some firewall/session metrics, CHF healthcheck totals).

Adjust `/ 60` if your poll interval is not 60 seconds (`poll_time_sec` in ktranslate config).

## Importing into Grafana Cloud Assistant

1. Copy the markdown body of each skill file (below the title) into a new **Assistant skill** on your stack.
2. Name them: `Network Dashboard — Design Patterns` and `Network Dashboard — Expanding for New Hardware`.
3. Cross-reference: the expand skill should point assistants at the design patterns skill.
4. After UI edits to dashboards, re-export manifests (gcx v2 or HTTP GET) — do not rely on stale JSON.

## Safe dashboard edits (v2 TabsLayout)

- **GET** full manifest → edit `spec.elements` / layout → **PUT** with `resourceVersion`
- **Do not** `POST /api/dashboards/db` on tabbed v2 boards (flattens tabs)

See also: [docs/grafana.md](../docs/grafana.md) in this repo for UID migration and fleet dashboard notes.

## network-o11y-demo lab (optional)

This repo's local lab uses the same skills with extra helpers under `local/`:

- Live dashboard pulls: `make -C local dash-live-sync`
- SNMP profiles: `local/snmp-profiles/`
- Operator PromQL notes: `local/docs/dashboard-query-lessons.md`

Those paths are **not** required on other stacks.
