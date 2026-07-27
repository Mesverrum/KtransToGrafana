# Network Dashboards — Design Patterns

Reference for visual and structural consistency in a **ktranslate-based Network Device Details** dashboard. Apply when adding panels, rows, or tabs on **any Grafana Cloud stack** running ktranslate.

**Companion skill:** [Expanding for New Hardware](network_dashboard_new_hardware.md)

**Portability:** Assumes ktranslate (`kentik_snmp_*`, `kentik_ping_*`). Does not assume specific hostnames, panel IDs, dashboard UIDs, or vendor MIBs unless labeled as examples.

---

## Conventions used in this document

| Symbol | Meaning |
|--------|---------|
| `$device` | Your dashboard's **single-device** template variable (PromQL label is always `device_name`) |
| `$interface` | Interface selector variable (PromQL label typically `if_interface_name`) |
| `$datasource` | Prometheus datasource variable — never hardcode datasource UIDs |

Replace `$device` with whatever your import uses (`$instance`, `$device_name`, etc.).

---

## ktranslate data model (PromQL)

The upstream Assistant skill sometimes shows `rate(...)[$__rate_interval]` for counters. That applies to **true Prometheus counters**, not most ktranslate SNMP interface metrics.

| Metric family | Recommended | Avoid |
|---------------|-------------|-------|
| Interface octets (bps) | `(kentik_snmp_ifHCInOctets{device_name=~"$device"}) * 8 / <poll_sec>` | `rate(kentik_snmp_ifHC*Octets[...])` |
| Interface errors/s | `(kentik_snmp_ifInErrors{...}) / <poll_sec>` | `rate(kentik_snmp_if*Errors[...])` |
| Memory % | `kentik_snmp_MemoryUtilization` when exported | Manual `Used / (Used + Available)` |
| Flow bytes | `max_over_time(network_io_by_flow_bytes[...])` | `rate(network_io_by_flow_bytes[...])` |
| True counters (firewall sessions, CHF totals) | `rate(...[$__rate_interval])` | — |

Default `<poll_sec>` is **60** for ktranslate SNMP polls; match your poller `poll_time_sec`.

**Fleet vs drill-down filters:**

- **Device Details** (single device): `device_name=~"$device"` only — `provider` is redundant.
- **Device Summary** (fleet): may also use `provider=~"$provider"` alongside `device_name`.

**Stale series:** after collector moves or IP changes, old series may linger. Use `max by (device_name)(...)` on drill-down scalars to collapse duplicates.

---

## Layout structure

- **Root:** `TabsLayout`
- **Typical tabs:** Overview, Interfaces, Hardware Sensors, Connections, Telemetry (your import may differ)
- **Within each tab:** `RowsLayout` → `GridLayout` rows
- **Grid width:** 24 columns

---

## Naming conventions

### Row vs panel titles

- **Row header** = section topic (e.g. "CPU Utilization", "Memory")
- **Stat** = current value — may share the row name
- **Timeseries** = distinct title — append **" Over Time"** or describe breakdown
- **Table** = descriptive suffix — "Peer Status", "Sensor Data", not the same as the row title

---

## Conditional rows (`has_*` variables)

Hidden QueryVariables gate rows. Non-empty → show row; empty → hide row.

```
kind: QueryVariable
name: has_<feature>
hide: hideVariable
refresh: onTimeRangeChanged
query:
  group: prometheus
  qryType: 1   # LabelValues
  label: device_name
  metric: <gate metric — must exist when row should show>
  labelFilters: [{ device_name =~ "$device" }]
```

**Row visibility:**

```
visibility: show
condition: and
items: [{ kind: ConditionalRenderingVariable, variable: "has_<feature>", operator: "matches", value: ".+" }]
```

### Metric-family rules

| Gate | Gate metric family |
|------|-------------------|
| `has_ping` | **`kentik_ping_*`** — e.g. `kentik_ping_PacketLossPct` — never `kentik_snmp_*` |
| Most SNMP rows | `kentik_snmp_*` matching what panels query |

### Dead gate metrics (common import bug)

The gate `metric` must be a series that **actually exists** for the device **and** matches what panels query. Examples seen in the wild:

| Symptom | Typical cause | Fix |
|---------|---------------|-----|
| Memory row hidden on modern profiles | Gate uses `hrStorageUsedPercent`, panels use `MemoryUtilization` | Point gate at `MemoryUtilization` |
| Ping row always hidden | Gate uses `kentik_snmp_*` | Use `kentik_ping_PacketLossPct` |
| Row visible but empty | Gate OK, panel query wrong | Align panel PromQL |

Verify with Explore: `count(<gate_metric>{device_name="<device>"})`.

---

## Dashboard variable stack (typical)

```
$datasource  →  $device  →  $interface (multi, includeAll)
```

- All queries use `$datasource` — no hardcoded UID.
- Base filter: `device_name=~"$device"`.
- Interface panels: `if_interface_name=~"$interface"` — do not hardcode `".*"`.

---

## Timeseries panel config

**Width threshold: 17 columns** (~70% of 24-col grid).

### Wide (≥ 17 cols)

```
lineWidth: 2
tooltip: { mode: multi }
legend: { displayMode: table, placement: right, calcs: [min, mean, max] }
```

### Compact (< 17 cols)

In/Out pairs (12+12):

```
lineWidth: 1
tooltip: { mode: single }
legend: { calcs: [] }
```

Shared defaults: `palette-classic`, `min: 0`, `fillOpacity: 10`, `spanNulls: 600000`, `stacking.mode: none`.

### Flow tab exception

Stacked **area** for NetFlow/sFlow — intentional deviation:

```
lineWidth: 0
fillOpacity: 80
spanNulls: false
legend: { calcs: [max] }
```

Do not normalize flow panels to standard line style.

---

## Panel pair (stat + timeseries)

| Width | Type | Role |
|-------|------|------|
| 7 | stat | Current KPI |
| 17 | timeseries | Trend |

---

## In/Out split (interface metrics)

Two panels — never combined:

```
Left:  x:0,  width:12 — title suffix " In"
Right: x:12, width:12 — title suffix " Out"
```

Traffic, utilization, errors, drops, error %, unicast/broadcast/multicast, queue drops.

---

## Table panels

- **Width:** 24 cols default
- **Query:** `instant: true`, `range: false`
- **No** `format: table` on Prometheus targets — use transformations
- **One query per panel** unless using SQL Expression to JOIN frames

### Column cleanup (`organize`)

Always hide collector/metadata labels, including **`deployment_host`** (ktranslate host — not the network device):

`Time`, `Index`, `__name__`, `device_name`, `deployment_host`, `job`, `instrumentation_name`, `eventType`, `entity_serial`, `entity_model`, `mib_name`, `mib_table`, `objectIdentifier`, `poll_duration_sec`, `provider`, `service_name`, `src_addr`, `tags_container_service`, `tags_kentik_model`

Prefer **string state labels** on series when ktranslate emits them alongside numeric values.

---

## Series-to-table: `labelsToFields → merge → organize`

Required for multi-series state tables (BGP, OSPF, fans, PSU, NTP, stack members, etc.).

1. **labelsToFields** — labels become columns
2. **merge** — **required**; without it only the first series row appears
3. **organize** — exclude noise + rename; exclude leftover numeric metric column

**Symptoms:**

| Symptom | Missing step |
|---------|----------------|
| Only 1 row | `merge` |
| `metric{label=...}` header | `labelsToFields` |
| Wrong colors on state | override targets string column, not numeric `Value` |

---

## Dynamic state-as-label metrics

ktranslate may encode state as numeric value **and** string label. State transitions create **new series**; stale series linger ~5 min → duplicate instant-table rows.

**Dedup:** `topk by (device_name, <entity_key>) (1, <metric>{device_name=~"$device"})` — prefer higher ordinal FSM values when applicable (confirm enum per vendor MIB).

Do not rely on timestamp-based dedup alone — stale and new series often share scrape time.

---

## Table column naming

- `entity_name` → `Component`; `if_interface_name` → `Interface`
- `*OperStatus`/`*OperState` → `Oper Status`
- State enums → `State`
- Units in headers: `Temp (°C)`, `Speed (RPM)`, `RTT (ms)`

After `labelsToFields`, exclude the numeric metric column (e.g. `kentik_snmp_tBgpPeerNgConnState`).

---

## Status column colors

1. Value mappings with semantic colors
2. `custom.cellOptions: { type: "color-background" }`

Multi-query SQL tables: use **`byFrameRefID`** overrides — not `defaults.mappings`.

---

## PromQL quick reference

```promql
# Device-level scalars
max by (device_name) (kentik_snmp_CPU{device_name=~"$device"})

# Interface-level
sum by (if_interface_name) ((kentik_snmp_ifHCInOctets{device_name=~"$device", if_interface_name=~"$interface"}) * 8 / 60)

# Ping (separate metric family)
avg by (device_name) (kentik_ping_AvgRttMs{device_name=~"$device"})
```

- **Stats/tables:** instant queries
- **Timeseries:** range queries (`instant: false`)

---

## See also

- [Expanding for New Hardware](network_dashboard_new_hardware.md)
- [Skills README](README.md) — prerequisites and variable mapping
