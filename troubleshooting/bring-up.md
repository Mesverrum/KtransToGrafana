# First-time bring-up: where data actually gets stuck

[← back to README](../README.md)

Discovery wrote `state/devices-*.yaml` but Grafana Explore is empty. That is the usual first-time failure — not “OTLP is broken.” Walk the hops in order. Do not skip to Grafana Cloud until the earlier hop is green.

```
devices  →  ktranslate poller  →  Alloy (local :12346)  →  Grafana Cloud (PromQL)
```

## Hop 1 — did discovery keep any devices?

```
cat state/devices-<group>.yaml
```

Replace `<group>` with the `GROUP=` value from your `groups/*.env` (usually `onboarding`).

| What you see | Meaning |
|---|---|
| A `devices:` list with IPs / names | Discovery worked. Go to hop 2. |
| `{}` or a missing file | Discovery never populated the poller. Run `make discover GROUP=<name>` (that is the **only** make target that honors `GROUP=`). Then `snmpwalk` from this host — [snmp.md](snmp.md). |

`make generate` and `make up` start **every** file matching `groups/*.env`. `GROUP=` does nothing there. Start with **one** group file (`groups/onboarding.env`) until hop 3 is green.

Leftover containers from an earlier try:

```
docker ps -a --format '{{.Names}}' | grep -i ktrans
```

`make down` then remove orphans if names do not match the current group. Then `make generate && make up` again.

## Hop 2 — is Alloy receiving on this host?

Do **not** open `GC_OTLP_URL` in a browser. Grafana Cloud OTLP is `POST /otlp/v1/metrics`; `GET /otlp` returns 404 and proves nothing.

Check the **local** Alloy hop first (Alloy exposes Prometheus scrape metrics on the host):

```
curl -s http://localhost:12346/metrics | grep otelcol_receiver_accepted
```

Counters increasing means ktranslate is handing data to Alloy on this machine. If that is empty or Alloy is restarting:

```
docker logs alloy --tail 80
```

| Log / symptom | Fix |
|---|---|
| Alloy crash loop after you used to copy `compose-base.yaml` / `config.alloy` | Delete those gitignored copies so `make up` uses the tracked `.sample` files. A leftover `/opt/Grafana/...` bind-mount or single-quoted `delete_matching_keys` is why those copies existed. |
| `deployment.host=` / invalid resource attributes | `.env` has blank `KTRANS_HOST` and you started with raw `docker compose up`. Use `make up` (fills hostname) or `export KTRANS_HOST=$(bash scripts/host-id.sh)` first. |

`make preflight` warns if leftover `compose-base.yaml` / `config.alloy` copies are sitting unused. To fork Alloy on purpose, see [architecture.md § Customizing Alloy and Compose](../docs/architecture.md#customizing-alloy-and-compose).

## Hop 3 — Grafana Cloud, with the right PromQL

This stack exports **per-metric** SNMP names over OTLP (`kentik_snmp_CPU`, `kentik_snmp_PollingHealth`, `kentik_snmp_ifHCInOctets`, …). There is **no** `kentik_snmp_DeviceMetrics` series here. That name belongs to Grafana Cloud’s AWS `integrations/snmp` dashboards. An empty DeviceMetrics query is not proof that the collector is down.

In Explore → Prometheus:

```
count by (tags_snmp_group, device_name) (kentik_snmp_CPU)
```

or:

```
count by (tags_snmp_group, device_name) (kentik_snmp_PollingHealth)
```

One row per polled device. `tags_snmp_group` matches the `GROUP=` name in `groups/*.env`.

If hop 2 is green and these queries are still empty:

- `GC_OTLP_URL`, `GC_OTLP_ACCOUNT`, and `GC_OTLP_KEY` must come from the **same** Grafana Cloud stack (same **Connections → OpenTelemetry** snippet). Mixing a `us-east-2` gateway with another region’s instance ID/token fails quietly from the operator’s point of view.
- Confirm you are exploring **that** stack, not another org you have in the browser.
- Wait ~1–2 minutes after the poller starts; SNMP is not instant.

## Failure modes that look like “the README is wrong”

These are the ones operators hit when following the samples literally.

| What you did | What actually happens |
|---|---|
| Copied every `groups/*.env.sample` | `make generate` / `make up` start **all** of them. Two SNMP pollers, colliding ports, leftover `ktranslate_snmp_*` containers. |
| Left `compose-base.yaml` / `config.alloy` in the repo root | Those copies are **unused** on Compose (`make up` uses the `.sample` files). Delete them, or follow [architecture.md § Customizing Alloy and Compose](../docs/architecture.md#customizing-alloy-and-compose). |
| `make generate GROUP=onboarding` or `make up GROUP=onboarding` | `GROUP=` is ignored. Those targets always process every `groups/*.env`. Only `make discover GROUP=…` uses it. |
| `chmod +x` on one script at a time after “Permission denied” | Git on Windows / some zip extracts drop `+x`. `make` already runs `bash scripts/…`. One-shot: `chmod a+x scripts/*.sh` (also done by `make preflight`). |
| `curl` / browser GET on `GC_OTLP_URL` | 404. Use hop 2 (`localhost:12346`) instead. |
| Queried `kentik_snmp_DeviceMetrics` | Empty on this path even when SNMP is healthy. Use `kentik_snmp_CPU` / `kentik_snmp_PollingHealth`. |
| `rate(network_io_by_flow_bytes[5m])` | ktranslate flow rollups are **gauges** emitted every `--rollup_interval` (60s). Throughput is `sum(network_io_by_flow_bytes) * 8 / 60`. Use `max_over_time` on dashboards, not `rate()`. |
| Raw `docker compose up` with blank `KTRANS_HOST` | Compose interpolates `deployment.host=` and Alloy can crash. Prefer `make up`. |
| Scripts invoked as `./scripts/foo.sh` from cron | Still needs `+x`, or write `bash scripts/foo.sh`. |
