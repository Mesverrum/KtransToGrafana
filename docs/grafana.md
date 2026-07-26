# Data in Grafana

[← back to README](../README.md)

Within a couple minutes of ktranslate polling your devices there should be data in your Grafana Cloud's default Prometheus data source. Metrics start with `kentik_snmp_*` and carry labels like `device_name` and `if_interface_name` based on the SNMP profile assigned during discovery.

Each poller stamps its own `service.name` (a label identifying which collector produced the data — `ktranslate-snmp-cisco`, `ktranslate-snmp-palo`, etc. — plus a `-<host>` suffix when `KTRANS_HOST` is set) so you can split dashboards by credential group, and by host across multiple deployments. Discovery containers use `ktranslate-discover-<group>` for the same reason — distinguishable in logs without polluting the poller's data. See [operations.md § Telling multiple deployments apart](operations.md#telling-multiple-deployments-apart).

## Quick verification

Open Grafana Cloud → Explore → your default Prometheus data source, and paste this query (written in PromQL, Grafana's metrics query language):

```
count by (device_name, service_name) (kentik_snmp_DeviceMetrics)
```

You should get one row per polled device, grouped by which credential group is polling it. If the table is empty after a couple minutes, check `make logs` for discovery activity and confirm `snmpwalk` works from the Docker host to one of your devices (see `troubleshooting/snmp.md`).

Network gear cardinality — the number of distinct metric time series, which is what Grafana Cloud usage is measured in — is all over the place: a UPS might emit ~50 active series, a large core switch or load balancer might emit 10,000. Plan accordingly.

## Flow data and cardinality

Flow data is high volume, so the `ktranslate_flow` container uses the `--rollups` argument in `compose-base.yaml` to convert raw flow records into a smaller collection of metric series. This is far more cost-effective to store and query than raw flow log lines. The [Sankey panel](https://grafana.com/grafana/plugins/netsage-sankey-panel/) works well to visualize this data after applying the `Group by` transformation to sum bytes.

Two flags govern the cardinality ceiling for the flow metric:

- **`--rollup_interval=60`** — emit one batch of rolled-up series every 60 seconds.
- **`--rollup_top_k=100`** — only emit the top 100 series (by aggregated value) in each batch.

Active-series math: `max ≤ rollup_top_k × (active_series_window / rollup_interval)`. With Grafana Cloud's typical 20-minute active-series window: `100 × (1200 / 60) = 2,000 series` as the worst-case ceiling. In practice traffic patterns are sticky, so steady state is usually a fraction of that.

## Compatibility with the official Grafana Cloud netflow integration

The flow pipeline is aligned with the [official Grafana Cloud ktranslate-netflow integration](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/integrations/integration-reference/integration-ktranslate-netflow/) — `config.alloy.sample` includes an `otelcol.processor.transform "preprocessing"` block (a small Alloy rule that rewrites the data) that renames `kentik.rollup.bytes_by_flow` to `network.io.by_flow` and remaps the flow attributes (`src_addr`, `dst_addr`, `dst_port`, etc. — the labels attached to the data) to OTEL semantic-convention names (the standard OpenTelemetry field names) like `network.local.address` and `network.peer.port`. The flow container's data also gets `service.name=integrations/ktranslate-netflow` so it shows up under that name in Grafana.

What this means in practice:

- You can import the **Netflow overview** dashboard from the official integration page and it will light up against this pipeline.
- The bundled `dashboards/Ktranslate Flow Summary.json` queries the new OTEL semconv metric and label names.
- SNMP and discovery containers set their own `OTEL_SERVICE_NAME` (a label identifying which collector produced the data — `ktranslate-snmp-<group>` / `ktranslate-discover-<group>`, plus the `-<host>` suffix when `KTRANS_HOST` is set) so the preprocessing transform's `service.name` rewrite skips them.

## Dashboards, alerts, and skills

The repo ships a set of assets to get you started:

- **`dashboards/`** — v2 Grafana manifests (import via UI or gcx v2 — **not** legacy `POST /api/dashboards/db` on tabbed boards):
  - **`00 Ktranslate Architecture`** — deployment guide and links
  - **`01 Ktranslate Health`** — collector CHF / jchf health by `service_name`
  - **`02 Network Flow Summary`** — NetFlow/sFlow rollups (`network_io_by_flow_bytes`)
  - **`03 Network Device Summary`** — fleet overview (TabsLayout)
  - **`04 Network Device Details`** — per-device drill-down (TabsLayout)
  - Legacy/auxiliary: `Ktranslate Flow Summary`, `ktranslate network fleet overview`, `ktranslate snmp device view`
- **`alerts/`** — example alert rules, a contact point, and a notification template you can adapt.
- **`skills/`** — portable guides for network dashboard design and onboarding new hardware ([`skills/README.md`](../skills/README.md)). Copy into Grafana Cloud Assistant or use as agent context when extending dashboards.
