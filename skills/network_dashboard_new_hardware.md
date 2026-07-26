# Network Dashboard — Expanding for New Hardware

Use when a **new device type** (ktranslate SNMP profile or vendor) is added and the **Network Device Details** dashboard should cover it correctly — on any Grafana Cloud stack.

**Panel standards:** [Design Patterns](network_dashboard_design.md)

**Convention:** `$device` = your single-device dashboard variable (PromQL label `device_name`).

---

## Overview

The dashboard uses **`has_*` conditional rows**. Each row renders only when the selected device reports the gate metric. Adding a device type means:

1. Discover what metrics it reports
2. Map metrics to existing `has_*` rows (often no changes)
3. Identify gaps
4. Build new `has_*` variables + rows for gaps
5. Validate show/hide behavior

---

## Step 1 — Discover metrics

**Live Prometheus (any stack):**

```promql
count by (__name__) ({device_name=~"$device"})
```

Or in Explore: label values for `__name__` with selector `{device_name=~"$device"}` and filter `kentik_.*`.

**Grafana MCP / Assistant tools:**

- `search_label_values` — label `__name__`, selector `{device_name=~"$device"}`, regex `kentik_.*`

**SNMP profile (expected vs actual):**

- Kentik upstream: [snmp-profiles](https://github.com/kentik/snmp-profiles/tree/main/profiles/kentik_snmp)
- Your fork or custom profiles in your deployment

Profile = expected; Prometheus = what is actually arriving. Use both.

---

## Step 2 — Map to existing rows

List dashboard variables prefixed `has_`. Each gate's **`metric`** field defines which metric family the row needs.

If the new device already exports that metric → row auto-shows. **No dashboard change.**

Discover variables via:

- Dashboard **Settings → Variables**
- Exported v2 manifest (`spec.variables` or classic `templating.list`)
- gcx: `dashboards get <uid>`

All `has_*` filters should use `device_name=~"$device"` (or your equivalent).

### Example gate metrics (verify on your fleet — not universal constants)

| Variable | Example gate metric | Notes |
|----------|---------------------|-------|
| `has_ping` | `kentik_ping_PacketLossPct` | Not `kentik_snmp_*` |
| `has_cpu` | `kentik_snmp_CPU` | |
| `has_memory` | `kentik_snmp_MemoryUtilization` *or* `hrStorageUsedPercent` | Match what panels query |
| `has_interfaces` | `kentik_snmp_if_OperStatus` | |
| `has_polling` | `kentik_snmp_PollingHealth` | |
| `has_bgp` | vendor-specific, e.g. `tBgpPeerNgConnState` | Confirm via live query |

---

## Step 3 — Identify gaps

Uncovered metrics that are **operator-meaningful** (health, state, capacity, errors) → candidates for new rows. Skip low-signal diagnostic OIDs.

Ask:

- Stat + timeseries pair, or table?
- Existing tab/section, or new row?
- Does an existing `has_*` gate cover a sibling metric?

---

## Step 4 — Build `has_*` variables

One hidden QueryVariable per new row **before** panels:

```
kind: QueryVariable
name: has_<feature>
hide: hideVariable
refresh: onTimeRangeChanged
query:
  group: prometheus
  qryType: 1
  label: device_name
  metric: <primary metric for this section>
  labelFilters: [{ device_name =~ "$device" }]
```

**Gate metric rules:**

1. Must return label values when the device supports the feature
2. Must match the **same metric family** panels query (see Design Patterns — ping vs SNMP)
3. Confirm live: `count(<metric>{device_name="<device>"})`

---

## Step 5 — Build row and panels

Place per **Placement Guide**. Follow Design Patterns for layout, transforms, PromQL, and naming.

**Row conditional rendering:**

```
visibility: show
condition: and
items: [{ kind: ConditionalRenderingVariable, variable: "has_<feature>", operator: "matches", value: ".+" }]
```

**v2 TabsLayout edits:** GET manifest → edit `spec.elements` / tab layout → PUT with `resourceVersion`. Never `POST /api/dashboards/db` on tabbed boards.

---

## Step 6 — Validate

1. Select the **new device** in `$device`
2. New row **visible** with populated panels
3. Select a device **without** those metrics
4. Row **hidden** (not merely empty — empty indicates wrong gate or query)
5. Multi-row tables: confirm row count matches entity count (`merge` present)
6. Screenshot: layout, units, legends

```promql
count(<gate_metric>{device_name="<new-device>"})
max by(device_name)(<panel_metric>{device_name="<new-device>"})
```

---

## Placement guide

| Content | Tab (typical) |
|---------|----------------|
| CPU, memory, uptime KPIs | Overview |
| Interface / traffic | Interfaces |
| Temp, fan, power sensors | Hardware Sensors |
| Sessions, NAT, VPN counters | Connections |
| Polling / telemetry metadata | Telemetry |
| Large feature sets (full BGP table) | Consider new tab |

---

## See also

- [Design Patterns](network_dashboard_design.md)
- [Skills README](README.md)
