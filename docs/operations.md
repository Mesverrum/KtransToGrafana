# Operations

[← back to README](../README.md)

Day-2 concerns: permissions, memory, image pinning, scheduled discovery, the flow demo overlay, tagging multiple hosts, and the full Makefile reference.

## Make targets

```
make preflight              # check that .env / groups / generated configs are ready
make generate               # render configs and compose-groups.generated.yaml from groups/*.env
make bootstrap              # seed empty state/devices-<group>.yaml so pollers can start
make limits                 # compute per-container memory caps from host RAM
make limits-show            # preview per-container memory caps from host RAM (dry-run)
make up                     # runs preflight + bootstrap + limits, then docker compose up -d
make up-demo                # same as 'up' plus the host-sflow demo overlay (instant flow data)
make logs                   # tail logs from all containers
make down                   # stop and remove the stack
make discover GROUP=cisco   # one-shot discovery for one group; populates state/devices-cisco.yaml
make detect-net             # auto-fill HOST_NET in .env (only needed for the sflow demo overlay)
make host                   # print the deployment.host value this stack will use
```

`make up` is idempotent — it starts newly-added services without disturbing running ones. Pollers begin polling whatever devices are in their `state/devices-<group>.yaml`; until you've run discovery those are empty stubs (`{}`) and no SNMP traffic goes out. Run `make discover GROUP=<name>` for each group to populate them.

## Permissions

The discovery script writes files into `state/` that the containers (running as uid 1000) need to read. Set ownership once:

```
sudo chown -R 1000:1000 config/ state/
```

## Memory limits

On each `make up`, `scripts/compute-limits.sh` reads the host's available memory and writes `compose-limits.generated.yaml` with per-container caps. Docker Compose has no project-wide memory budget — each service gets its own limit — but the script sizes caps so their sum stays within a configurable fraction of available RAM. SNMP pollers receive the largest share, capped at **4G each**, which matches a typical **4 vCPU / 8 GiB** trial host running one poller plus alloy, flow, and syslog. Preview the plan without restarting with `make limits-show`.

`.env` knobs (see `.env.sample`):

- `MEM_BUDGET_FRACTION=0.80` — fraction of `MemAvailable` allocated across the stack
- `MEM_SNMP_MAX=4g` — per-poller ceiling (default 4g)
- `MEM_SNMP_LIMIT=4g` — hard override for every SNMP poller (skip auto math)
- `MEM_LIMITS=off` — disable limits entirely

## Pinning image versions

- `KTRANSLATE_IMAGE` / `ALLOY_IMAGE` — leave blank for `:latest`, or pin e.g. `quay.io/kentik/ktranslate:v2.2.37` / `grafana/alloy:v1.8.3`. After changing a pin, `docker compose pull` and recreate.

## Scheduled discovery

Add cron entries on the host so new devices get picked up automatically. Stagger each group a few minutes apart so they don't all run at once:

```
0  */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh cisco >> /var/log/ktrans-discovery.log 2>&1
5  */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh palo  >> /var/log/ktrans-discovery.log 2>&1
```

Each run scans the group's configured CIDRs (or queries NetBox, depending on its `DISCOVERY_SOURCE`), atomically publishes a fresh `state/devices-<group>.yaml`, and sends `SIGUSR2` to the matching poller so it picks up the new device list without a restart. (`SIGUSR2` is ktranslate's reload signal — `SIGHUP` has no handler and would terminate the container.) If discovery returns zero devices (network blip, container crash) the script preserves the previous device list rather than wiping it. If the device list is unchanged, no reload is sent.

## Instant flow data with the sflow demo overlay

To see flow data immediately, before any real router or switch is exporting netflow/sflow, an optional overlay (`compose-sflow.yaml`) runs `host-sflow` on the Docker host and points it at the `ktranslate_flow` container:

```
make detect-net   # auto-fills HOST_NET in .env with the host's default interface
make up-demo      # same as 'make up' but layers compose-sflow.yaml on top
```

`make up` does **not** include this overlay — it's off by default. `host-sflow` needs the host's primary interface set as `HOST_NET` in `.env`; `make detect-net` fills that in (it defaults to `ens4` otherwise). Once you have real flow sources pointed at UDP/9995, drop the overlay and go back to `make up`.

## Telling multiple deployments apart

If you run this stack on more than one host (e.g. one per site or datacenter), every signal can be tagged with which host produced it so hosts never get mixed up in Grafana. A single variable, `KTRANS_HOST`, controls this:

- **Leave it blank** (the default) and `make` auto-fills it with the machine's hostname, so each host self-identifies with no configuration.
- **Set it explicitly** in `.env` (e.g. `KTRANS_HOST=site-a`) if you'd rather use a friendlier name than the raw hostname. An explicit value always wins.

`KTRANS_HOST` does two things:

1. **Labels every metric, log, and trace** with `deployment_host`, applied by Alloy to everything it forwards — SNMP, flow, syslog, discovery, and ktranslate's own health metrics. Filter or group any query by `deployment_host` to scope it to one host. (The metric label is added by the `otelcol.processor.transform "add_resource_attributes_as_metric_attributes"` block in `config.alloy` — make sure your live `config.alloy` matches the current `config.alloy.sample` if you deployed before this was added.)
2. **Suffixes each container's `service.name`**, so the same workload on two hosts never shares a name — e.g. `ktranslate-snmp-cisco-site-a` vs `ktranslate-snmp-cisco-site-b`.

Check what a host will report before starting:

```
make host          # prints the resolved value
make up            # also prints "deployment.host = <value>" as it starts
```

The resolution logic lives in `scripts/host-id.sh` and is shared by `make` and the discovery cron job, so long-running and scheduled containers always agree. A raw `docker compose up` (bypassing `make`) reads `KTRANS_HOST` from `.env` verbatim and does **not** apply the hostname fallback — set the variable explicitly if you don't drive the stack through the Makefile.
