# Network Dashboard — Expanding for New Hardware

Use this process whenever a new device type (new ktranslate profile or vendor) is added to monitoring and you want the Network Device Details dashboard to cover it correctly.

For all panel construction standards (timeseries config, naming rules, layout patterns, PromQL conventions, metric family rules) refer to: **"Network Dashboard — Design Patterns"**

---

## Overview

The dashboard uses a `has_*` conditional-row system. Each row only renders when the selected device actually reports the metric that row covers. Adding support for a new device type means:

1. Discovering what metrics it reports
2. Mapping those metrics to existing rows (most will already be covered)
3. Identifying gaps — metrics with no row yet
4. Building new rows and `has_*` variables for the gaps

---

## Step 1 — Discover the Device's Metrics

Query Prometheus for all metric names the device reports:

```promql
label_values({device_name=~"$device_name"}, __name__)
```

Or via the prometheus_query_handler tool:
- operation: `search_label_values`
- label_name: `__name__`
- selector: `{device_name=~"$device_name"}`
- regex: `kentik_.*`

This returns the full set of `kentik_snmp_*` and `kentik_ping_*` metrics the device is sending.

**Also check the ktranslate SNMP profile** for the device's vendor/model at:
`https://github.com/kentik/snmp-profiles/tree/main/profiles/kentik_snmp`

The profile shows what metrics are *expected* — the live query shows what is *actually arriving*. Use both.

---

## Step 2 — Map Metrics to Existing Rows

Check what `has_*` variables currently exist in the dashboard. Each variable's gate metric tells you which metric family it covers. If a device metric matches a gate metric already in use, that row will automatically show or hide for the new device — no changes needed.

To discover existing variables, read the dashboard spec or query the dashboard's variable definitions and look for all variables prefixed `has_`.

The `has_*` variables filter by `device_name=~"$device_name"` so existing rows handle any device automatically once a matching variable is present.

---

## Step 3 — Identify Gaps

Subtract the covered metrics from the full device metric list. What remains are candidates for new rows.

**Before building anything, ask:**
- Is this metric meaningful to an operator at a glance? (If not, skip it.)
- Does it belong in an existing section with a different `has_*` gate, or does it need its own row?
- Is there a natural stat + timeseries pair, or is a table more appropriate?

**Deciding whether a metric warrants a new row:** if a metric carries health, state, or operational data for a hardware component, sensor, connection feature, or application-layer function that no existing row covers, it is a candidate. If it is a low-signal diagnostic OID unlikely to be acted on directly, skip it.

---

## Step 4 — Build New `has_*` Variables

For each new row, create a hidden QueryVariable before building the panels.

**Standard pattern:**
```
kind: QueryVariable
name: has_
hide: hideVariable
refresh: onTimeRangeChanged
query:
 group: prometheus
 qryType: 1 (LabelValues)
 label: device_name
 metric: 
 labelFilters: [{ device_name =~ "$device_name" }]
```

Pick the metric that will always be present if this device type is selected — typically the primary counter or status metric for the section.

Before choosing the gate metric, consult the **Design Patterns skill** for metric family rules (e.g., which metric families require their own variable rather than sharing with `kentik_snmp_*`-based variables).

---

## Step 5 — Build the Row and Panels

Add the row to the appropriate tab based on the Placement Guide below.

Follow the **Design Patterns skill** for all panel construction standards — layout, timeseries config, naming rules, PromQL conventions, table patterns, and status column colors.

Apply conditional rendering to the row:
```
visibility: show, condition: and
items: [{ variable: "has_", operator: "matches", value: ".+" }]
```

---

## Step 6 — Validate

1. Select the new device in the `$device_name` dropdown.
2. Confirm the new row is visible and panels are populated.
3. Switch to a different device type that does *not* have these metrics.
4. Confirm the row is hidden (not just empty).
5. Take a screenshot to verify layout, units, and legend placement.

---

## Placement Guide

| Content type | Where to add |
|---|---|
| Device health KPIs (CPU, memory, uptime) | Overview tab, new conditional row |
| Interface/traffic metrics | Interfaces tab, new conditional row |
| Physical sensor data (temp, fan, power) | Hardware Sensors tab, new conditional row |
| Session/connection/NAT/VPN counters | Connections tab, new conditional row |
| Polling or telemetry metadata | Telemetry tab |
| Very large feature set (e.g., BGP full table) | Consider a new tab |
