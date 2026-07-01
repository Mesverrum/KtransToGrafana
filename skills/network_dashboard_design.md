# Network Dashboards — Design Patterns

Reference for maintaining visual and structural consistency in a ktranslate-based Network Device Details dashboard. Apply these patterns when adding panels, rows, or new tabs to any deployment of this dashboard type.

---

## Layout Structure

- **Root layout:** `TabsLayout`
- **Tabs:** Overview, Interfaces, Hardware Sensors, Connections, Telemetry
- **Within each tab:** `RowsLayout` containing `GridLayout` rows
- **Grid width:** 24 columns

---

## Naming Conventions

### Row vs Panel titles
Row headers provide section context; panel titles should not simply repeat the row name.

**Pattern:**
- Row header = section topic (e.g., "CPU Utilization", "Memory", "Errors & Drops")
- Stat panel = current/summary value — can share the section name since it's clearly a KPI
- Timeseries panel = must be distinct from the stat — append " Over Time" or describe the specific breakdown (e.g., "CPU Utilization Over Time")
- Table panel = must not repeat the row name — use a descriptive suffix like "Sensor Data", "Peer Status", or "Current Readings"

**Good examples:**
- Row: "CPU Utilization" → Stat: "CPU Utilization" + Timeseries: "CPU Utilization Over Time"
- Row: "Errors & Drops" → Panels: "Errors In", "Errors Out", "Drops In", "Drops Out"
- Row: "NTP Peers" → Table: "NTP Peer Status"

**Bad examples (avoid):**
- Row: "CPU Utilization" → Timeseries also named "CPU Utilization" ← identical, no added context
- Row: "Temperature (°C)" → Table also named "Temperature (°C)" ← identical to row

---

## Conditional Row Pattern (`has_*` variables)

Rows that only apply to certain device types are shown conditionally using a hidden `has_*` QueryVariable. When the variable resolves to a non-empty value the row is shown; when empty (metric doesn't exist for the selected device) the row is hidden.

**Naming:** `has_` — e.g., `has_cpu`, `has_interfaces`, `has_sensors`, `has_fan_speed`.

A single `has_*` variable can control multiple rows when appropriate (e.g., `has_sensors` controls both the sensors summary row on Overview and the Hardware Values table on the Hardware Sensors tab).

**Variable spec:**
```
kind: QueryVariable
hide: hideVariable
refresh: onTimeRangeChanged
query:
 group: prometheus
 qryType: 1 (LabelValues)
 label: device_name
 metric: 
 labelFilters: [{ device_name =~ "CV-TF-1FL4510-North.commvault.com" }]
```

**Row conditional rendering:**
```
visibility: show
condition: and
items: [{ kind: ConditionalRenderingVariable, variable: "has_", operator: "matches", value: ".+" }]
```

### ⚠️ Exception: `has_ping` uses `kentik_ping_*`

Ping data from ktranslate lives in a **separate metric family** (`kentik_ping_*`), not `kentik_snmp_*`. Using a `kentik_snmp_*` metric for `has_ping` will always return empty and the Ping row will always be hidden.

```
has_ping:
 metric: kentik_ping_PacketLossPct ← kentik_ping_*, not kentik_snmp_*
```

---

## Dashboard Variables Stack

```
datasource (DatasourceVariable, pluginId: prometheus)
 → instance (QueryVariable, label: device_name, multi: false)
 → interface_name (QueryVariable, label: if_interface_name,
 labelFilters: [{ device_name =~ "CV-TF-1FL4510-North.commvault.com" }],
 multi: true, includeAll: true)
```

All panel targets use the datasource variable uid — never hardcode a datasource UID.

Base label filter in all panel queries: `device_name=~"CV-TF-1FL4510-North.commvault.com"`
Interface panels add: `if_interface_name=~"$interface_name"` ← must use the variable, never hardcode `".*"`

**Note:** `provider` is not used as a panel-level filter — `device_name` is always more specific. Remove any `provider=~"..."` filters in legacy panels.

---

## Timeseries Panel Config

Panel width determines which of two configs applies. The threshold is **17 columns** (≈70% of the 24-column grid).

### Wide panels (≥ 17 columns)

Used for stat+timeseries pairs (17-col timeseries), full-width panels (24 col), and any panel wide enough to display multi-series tooltips cleanly.

```
fieldConfig.defaults:
 color.mode: palette-classic
 unit: 
 min: 0
 custom:
 drawStyle: line
 lineWidth: 2
 fillOpacity: 10
 spanNulls: 600000
 showPoints: auto
 stacking.mode: none
 thresholdsStyle.mode: off

options:
 tooltip: { mode: multi, sort: none, hideZeros: false }
 legend: { displayMode: table, placement: right, showLegend: true, calcs: [min, mean, max] }
```

### Compact panels (< 17 columns)

Used for In/Out split pairs (12 col each) and any panel narrow enough that multi-series tooltips become unwieldy.

```
fieldConfig.defaults:
 color.mode: palette-classic
 unit: 
 min: 0
 custom:
 drawStyle: line
 lineWidth: 1
 fillOpacity: 10
 spanNulls: 600000
 showPoints: auto
 stacking.mode: none
 thresholdsStyle.mode: off

options:
 tooltip: { mode: single }
 legend: { displayMode: table, placement: right, showLegend: true, calcs: [] }
```

### Flow timeseries panels (exception)

Flow tab timeseries panels (panels 282, 283, 301, 303, 307, 309) visualize NetFlow/sFlow byte counts as stacked areas. They intentionally deviate from the standard config:

```
fieldConfig.defaults:
 min: 0
 custom:
 lineWidth: 0 ← no line; shape is filled area only
 fillOpacity: 80 ← heavy fill for stacked area appearance
 spanNulls: false ← gaps shown as gaps (flow export is intermittent)

options:
 tooltip: { mode: multi }
 legend: { calcs: [max] } ← max is most meaningful for traffic peaks
```

Do not "fix" these panels to the standard config — the stacked area style is intentional for flow data.

---

## Panel Pair Pattern (Stat + Timeseries)

Used for device-level metrics: CPU, Memory, etc.

| Column | Width | Type | Purpose |
|---|---|---|---|
| Left | 7 | stat | Current value, color-coded by threshold |
| Right | 17 | timeseries | Trend over time |

Optional second row within a section:
| Left | 4 | stat | Additional KPI |
| Left+1 | 3 | stat | Additional KPI |
| Right | 17 | timeseries | Companion trend |

---

## In/Out Split Pattern (Interface Metrics)

All directional interface metrics use two separate panels side by side — never combined.

```
Left: x:0, width:12, height:8 — Inbound (title: " In")
Right: x:12, width:12, height:8 — Outbound (title: " Out")
```

Applies to: Traffic, Utilization, Errors, Drops, Error %, Unicast/Broadcast/Multicast, Queue Drops.

---

## Table Panel Pattern

**Tables should use full width (24 columns) by default.** Only deviate when two closely related tables benefit from side-by-side comparison (e.g., Fan States vs Power Supply States in the same row).

**Required query settings for every Prometheus table query:**
```
instant: true
range: false
format: table ← without this, Prometheus returns one time-series frame per label set
 instead of a single flat wide-format table; the panel will not render correctly
```

**One query per panel is the default.** Each Prometheus query in a panel produces its own data frame. When a table panel has more than one query, Grafana shows a frame selector dropdown — the user must manually toggle between datasets and all but the selected one are hidden. This is an anti-pattern.

To keep everything visible in one table:
- Use a **SQL Expression** (type: sql) to JOIN frames from multiple queries on a shared label (e.g., `entity_name`). This merges them into a single frame with no selector.
- If two distinct metrics genuinely belong side by side but can't be joined, use **two separate 12-col panels** in the same row rather than one panel with a frame selector.

**Column cleanup (via organize transformation):**
- Hide: `Time`, `Index`, `__name__`, `device_name`, `job`, `instrumentation_name`, `eventType`, `entity_serial`, `entity_model`, `mib_name`, `mib_table`, `objectIdentifier`, `poll_duration_sec`, `provider`, `service_name`, `src_addr`, `tags_container_service`, `tags_kentik_model`
- Rename meaningful columns — see naming conventions below
- ktranslate often emits state values as **string labels** (e.g., `fan_state="normal"`) alongside the numeric metric. Prefer the string label column over value mappings on the numeric — it requires no mapping maintenance.

---

## Table Column Naming Conventions

All column headers must be human-readable and title-case. Never leave raw Prometheus label names or `kentik_snmp_*` prefixes visible.

**Implementation:**
- **Standard panels:** `organize` transformation with `renameByName` / `excludeByName`
- **SQL expression panels:** use `AS "Column Name"` directly in the SELECT — no transformation needed

### Naming rules (generalize from these patterns)

- Strip `entity_` prefix, title-case remainder: `entity_name` → `Component`, `entity_description` → `Description`, `entity_sensor_type` → `Sensor Type`
- Any `*OperStatus` / `*OperState` → `Oper Status`; `*AdminStatus` → `Admin Status`; `*AdminMode` → `Admin Mode`
- Any column holding a state or status enum → `State`
- Interface identifier: `if_interface_name` → `Interface` (or `Port` in a stack/chassis context)
- Neighbor/routing labels: `neighbor_ip` → `Neighbor IP`, `neighbor_id` → `Router ID`
- Append units in parentheses when the column carries a physical measurement: `Temp (°C)`, `Speed (RPM)`, `Current (mA)`, `RTT (ms)`

### ⚠️ labelsToFields panels: exclude the numeric value column

When `labelsToFields(mode: columns)` is used, Grafana creates two columns per metric: the string label (e.g., `cefcFanTrayOperStatus`) and a numeric value column (e.g., `kentik_snmp_cefcFanTrayOperStatus`). Explicitly exclude the numeric column — it is redundant.

```json
"excludeByName": {
 "kentik_snmp_cefcFanTrayOperStatus": true,
 "kentik_snmp_cefcModuleOperStatus": true,
 "kentik_snmp_cefcModuleAdminStatus": true,
 "kentik_snmp_redundancy_oper_mode": true
}
```

### Organize transformation baseline

```json
{
 "id": "organize",
 "options": {
 "excludeByName": {
 "Time": true, "Index": true, "__name__": true, "device_name": true,
 "job": true, "instrumentation_name": true, "eventType": true,
 "mib_name": true, "mib_table": true, "objectIdentifier": true,
 "poll_duration_sec": true, "provider": true, "service_name": true
 },
 "renameByName": {
 "entity_name": "Component",
 "entity_description": "Description",
 "entity_model": "Model",
 "entity_serial": "Serial",
 "entity_class": "Class"
 }
 }
}
```

Extend `renameByName` and `excludeByName` as needed — the above is the minimum baseline.

---

## Status Column Color Override Pattern

Any table column containing a state or status value must have:
1. **Value mappings** converting codes to human-readable labels with colors
2. **`custom.cellOptions: { type: "color-background" }`** so the color fills the cell

### Standard color semantics

| State keyword(s) | Color |
|---|---|
| `normal` / `ok` / `good` / `up` / `active` / `ready` / `full` / `healthy` / `redundant` | green |
| `warning` / `progressing` / `learn` / `listen` / `twoWay` | yellow |
| `standby` / `speak` / `attempt` / `exchangeStart` / `exchange` / `loading` | orange or blue |
| `critical` | orange |
| `shutdown` / `down` / `error` / `bad` / `failed` / `removed` / `forcedDown` / `init` | red |
| `notPresent` / `notFunctioning` / `inactive` / `disabled` / `unknown` / `initial` | blue or gray |

### Implementation — string state columns

```json
{
 "matcher": { "id": "byName", "options": "State" },
 "properties": [
 { "id": "mappings", "value": [{ "type": "value", "options": {
 "normal": { "text": "normal", "color": "green", "index": 0 },
 "warning": { "text": "warning", "color": "yellow", "index": 1 },
 "critical": { "text": "critical", "color": "orange", "index": 2 },
 "shutdown": { "text": "shutdown", "color": "red", "index": 3 },
 "notFunctioning": { "text": "notFunctioning", "color": "blue", "index": 4 }
 }}]},
 { "id": "custom.cellOptions", "value": { "type": "color-background" } }
 ]
}
```

### Implementation — numeric state columns

Same structure with numeric string keys (`"1"`, `"2"`, etc.) instead of state names.

### When to use `byFrameRefID` instead of `byName`

When a table panel has multiple instant queries joined via SQL Expression, each source query is still a separate frame before the SQL step. Use `byFrameRefID` in overrides to target a specific source frame's column — this prevents one query's state mapping from applying to another query's value column.

### ⚠️ Do NOT use `defaults.mappings` for multi-query tables

`fieldConfig.defaults.mappings` applies to ALL value columns across ALL frames. Use `byFrameRefID` overrides instead.

### Known status columns in this dashboard

| Panel | Column | Type | Color map |
|---|---|---|---|
| OSPF Neighbor Status (239) | State | string | down/red, attempt/orange, init/yellow, twoWay/yellow, exchangeStart/blue, exchange/blue, loading/blue, full/green |
| Temperature Sensor Data ENVMON (244) | State | string | normal/green, warning/yellow, critical/orange, shutdown/red, notFunctioning/blue |
| Stack Switch & Port States (264) | State (frame A, cswSwitchState) | numeric | 1=ready/green, 2=progressing/yellow, 3=added/blue, 4=removed/red |
| Stack Switch & Port States (264) | State (frame B, cswStackPortOperStatus) | numeric | 1=up/green, 2=down/red, 3=forcedDown/orange |
| HSRP Group States (266) | State | numeric | 1=initial/blue, 2=learn/yellow, 3=listen/yellow, 4=speak/blue, 5=standby/orange, 6=active/green |
| Power Supply States (273) | State | numeric | 1=normal/green, 2=warning/yellow, 3=critical/orange, 4=shutdown/red, 5=notPresent/blue, 6=notFunctioning/blue |
| Temperature Sensor Data SG (274) | Status | numeric | 1=normal/green, 2=warning/yellow, 3=critical/red |

---

## PromQL Conventions

- Always use `device_name=~"CV-TF-1FL4510-North.commvault.com"` — required for Grafana variable interpolation
- `max by (device_name)` for device-level scalar metrics (CPU %, memory %, counts)
- `sum by (if_interface_name)` for interface-level rate metrics
- `rate(...)[$__rate_interval]` for counters; multiply octets × 8 for bits
- `instant: true` for stat and table panels; `range: true` for timeseries

### `kentik_ping_*` query examples
```promql
avg by (device_name) (kentik_ping_PacketLossPct{device_name=~"CV-TF-1FL4510-North.commvault.com"})
avg by (device_name) (kentik_ping_AvgRttMs{device_name=~"CV-TF-1FL4510-North.commvault.com"})
max by (device_name) (kentik_ping_MaxRttMs{device_name=~"CV-TF-1FL4510-North.commvault.com"})
min by (device_name) (kentik_ping_MinRttMs{device_name=~"CV-TF-1FL4510-North.commvault.com"})
```
