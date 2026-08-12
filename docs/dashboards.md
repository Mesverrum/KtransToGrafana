# Bundled dashboards — import the set

[← back to README](../README.md) · [Data in Grafana](grafana.md)

This repo ships a small **numbered dashboard set** under [`dashboards/`](../dashboards/). Import **the whole set** (00–04), not a single board in isolation — Summary links into Details, Architecture explains the model, and Health tells you whether collectors are alive before you chase empty panels.

| # | File | Role |
|---|------|------|
| 00 | `00 Ktranslate Architecture.json` | How the pipeline fits together + links into the other boards |
| 01 | `01 Ktranslate Health.json` | Collector CHF / jchf health (`service_name`, `$snmp_group`) |
| 02 | `02 Network Flow Summary.json` | NetFlow / sFlow rollups |
| 03 | `03 Network Device Summary.json` | Fleet overview → drill into a device |
| 04 | `04 Network Device Details.json` | Per-device drill-down (tabs + conditional rows) |

**Push (preferred):** add `GRAFANA_URL` + `GRAFANA_TOKEN` to `.env`, then:

```bash
python3 scripts/push-dashboards.py
```

Details: [grafana.md § Dashboards](grafana.md#dashboards-alerts-and-skills). Use the **v2** dashboard API (or gcx) for updates — never legacy `POST /api/dashboards/db` on tabbed boards (it flattens tabs).

---

## One Device Details board, many device types

**`04 Network Device Details` is intentionally a single dashboard** that covers switches, routers, firewalls, wireless, UPS/PDU, storage appliances, and more — rather than a separate dashboard per vendor or role.

### Why

- Operators pick a **device** and stay on one board. Tabs (Overview, Interfaces, Hardware Sensors, Connections, Flow, Events, Telemetry) stay stable; only the rows that apply to *that* device appear.
- ktranslate already normalizes many SNMP profiles into shared metric families (`kentik_snmp_*`). When a new profile reuses those names, **existing rows light up with no dashboard change**.
- Vendor-specific extras (BGP peers, UPS battery, WLAN stations, …) sit behind **`has_*` gates**: if the selected device does not export the gate metric, the row stays hidden. You do not scroll past empty Cisco panels on a UPS, or empty UPS panels on a spine.
- Maintaining **one** TabsLayout board is cheaper than keeping N vendor clones in sync when PromQL patterns, bps math, or table transforms change.

### How `has_*` hide logic works

1. Hidden dashboard variables named `has_<capability>` run a small Prometheus query (usually `label_values` on a gate metric filtered by `$instance` / `device_name`).
2. Each conditional **row** is tied to one of those variables: non-empty → show; empty → hide.
3. Panels inside a shown row query the same families the gate tested for — so visibility and data stay aligned.

Adding coverage for a new MIB or vendor is usually: pick a gate metric that exists when the feature is present → add `has_*` → add a row/panels on the right tab. See [`skills/network_dashboard_new_hardware.md`](../skills/network_dashboard_new_hardware.md).

### What this is not

- It is **not** “show every panel for every device.” Hide logic is the point.
- It is **not** a replacement for Summary (fleet) or Flow (conversation) boards — those stay separate because the question is different.
- Dense `has_*` lists cost a bit of load on dashboard open (each gate is a Prom lookup). That tradeoff is accepted so one Details board can stay broad; revisit only if open time becomes painful (then consolidate gates or split role spokes — do not casually delete coverage).

### PromQL caveat (hyphenated metric names)

Some profiles export names with hyphens (e.g. RoomAlert `kentik_snmp_digital-sen1-1`). Those are **illegal** as bare PromQL identifiers. Gates and panel exprs must use `{__name__="kentik_snmp_…", …}` instead of `kentik_snmp_…{…}`.
