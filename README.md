# KtransToGrafana
This repo is an example of a quick time to value deployment of [Ktranslate](https://github.com/kentik/ktranslate/) writing to a [Grafana Cloud](https://grafana.com/products/cloud/) OTLP endpoint. While there are countless approaches to accomplish this I am hoping to provide a simple, functional example without requiring too much Linux or Alloy expertise. You should be able to have SNMP data showing up in your Grafana account in about 10-15 minutes.

This repo is not maintained by Kentik or Grafana, it is just a demonstration of how to easily connect the two tools together. Questions about the example configs can be raised at this repo, bugs or feature requests for either tool should be directed at their respective repos.

If you run into problems you can check the ```troubleshooting``` folder in this repo for some more help.

## Deployment model
There is now a single unified model. A deployment is **N credential groups**, one declarative file each under `groups/<name>.env`, rendered by a config generator into per-group configs plus a compose fragment. You no longer pick a branch — you pick which shape each group takes:

- Every group sets **`DISCOVERY_SOURCE=cidr|netbox`** (defaults to `cidr` if unset).
  - **`cidr`** — set `TARGETS` to the CIDRs / `/32` IPs to scan.
  - **`netbox`** — set `NETBOX_*` filters and let ktranslate pull the device list from NetBox.
- A **single device** is just the degenerate case: one `cidr` group with one target. That's the fast on-ramp — see the quickstart below.
- Mix and match freely: one deployment can have a CIDR group for one vendor and a NetBox group for another, all polling side by side.

> This repo previously used separate branches for these shapes (`main` = single poller, `multicontainer_example` = per-group CIDR discovery, `multicontainer_netbox` = per-group NetBox discovery); they have all been consolidated into this one model on `main`, so if you bookmarked one of the old branches, everything now lives here.

## Architecture
This example deploys a small set of containers via Docker Compose:
- **`ktranslate_flow`** — receives netflow data (netflow 5/9, sflow, ipfix, nbar, pan, etc.) and converts it to OTEL metrics via configurable rollups.
- **`ktranslate_snmp_<group>`** — one long-running SNMP poller per credential group. Each reads a static config file from `config/` plus a separately-managed device list from `state/`.
- **`discover_<group>`** — one short-lived discovery container per credential group. Runs on a schedule, writes discovered devices back to `state/`, and signals the matching poller to reload.
- **`ktranslate_syslog`** — collects syslog and forwards as OTEL logs.
- **`alloy`** — a stripped-down Grafana Alloy agent that forwards all OTLP traffic from the above to Grafana Cloud.

Each credential group (e.g. `cisco`, `palo`, `fortinet`) is defined by a single declarative file in `groups/<name>.env`. A generator script reads those files and renders the per-group config yamls plus a compose service fragment. Adding a new credential group is a one-file operation followed by a re-run of the generator.

The split between discovery and polling lets git stay the source of truth for credentials, scan ranges, and polling rules, while letting the network itself be the source of truth for which devices currently exist. Discovery writes are atomic and reversible; polling configs are mounted read-only and never mutated.

![Architecture](./ktrans_architecture.png)
![Detail](./ktrans_to_alloy.png)

## Usage Instructions

### Prerequisites
Start with an Ubuntu Linux system (also tested under Windows WSL).

Install Docker and Docker Compose per their [documentation](https://docs.docker.com/compose/install/linux/#install-using-the-repository), plus `yq` (Mike Farah's version, for the discovery script) and `envsubst` (for the generator):
```
sudo apt install yq gettext-base
```
Verify everything is in place:
```
docker run hello-world
docker compose version
yq --version
envsubst --version
```

Clone this repo into the directory where you intend to store your ktranslate deployment:
```
git clone https://github.com/Mesverrum/KtransToGrafana.git
cd KtransToGrafana/
```

### Quickstart: one device in ~5 minutes
If you just want data from a single device, skip the multi-group ceremony. First get the base files and your Grafana Cloud credentials in place — copy the samples (`cp .env.sample .env`, `cp config.alloy.sample config.alloy`, `cp compose-base.yaml.sample compose-base.yaml`) and fill in `GC_OTLP_URL` / `GC_OTLP_ACCOUNT` / `GC_OTLP_KEY` in `.env` (see [Set Grafana Cloud credentials](#set-grafana-cloud-credentials-in-env) below). Those creds are always required first.

Then copy the minimal single-device group and point it at your device:
```
cp groups/single.env.sample groups/single.env
# edit groups/single.env: set TARGETS to your device (e.g. 192.168.1.1/32) and the SNMP community
make generate && make up && make discover GROUP=single
```
`groups/single.env` is an ordinary `cidr` group with one target — when you're ready for more, copy the other samples (or copy `single.env.sample` again) to add groups. The rest of this document walks through each step in detail.

### Copy the sample files
The base files (env, Alloy, compose) are one-time copies — local edits stay yours and won't be overwritten on `git pull`:
```
cp .env.sample .env
cp config.alloy.sample config.alloy
cp compose-base.yaml.sample compose-base.yaml
```
If you already customized a tracked `compose-base.yaml` before this change, rename it to `compose-base.yaml` (or merge your edits into a fresh copy from the sample) so pulls stop conflicting. The `config.alloy` you just copied carries the `deployment_host` promotion (see [Telling multiple deployments apart](#telling-multiple-deployments-apart)) — if you deployed before that was added, refresh your live `config.alloy` from the current sample.

The credential groups are managed under `groups/`. Three sample groups ship in the repo — copy whichever fit your environment:
```
cp groups/single.env.sample groups/single.env   # minimal single-device CIDR group
cp groups/cisco.env.sample  groups/cisco.env     # CIDR discovery, SNMP v3 example
cp groups/palo.env.sample   groups/palo.env      # NetBox discovery, SNMP v2c example
```
Copy only the ones you need (a single device just needs `single.env`), and copy additional sample files to define more groups (e.g. `cp groups/cisco.env.sample groups/fortinet.env`). The generator picks up everything matching `groups/*.env`.

### Set Grafana Cloud credentials in `.env`
Log in to your Grafana Cloud account and search for `Add new connection`, then in that screen search for `otlp` and select the `OpenTelemetry` tile. Create a new token or use an existing one. Skip past the Alloy install instructions — you don't need to deploy Alloy from there. Scroll down to `Append the generated configuration to your configuration file` and find the snippet that looks like this:
```
otelcol.exporter.otlphttp "grafana_cloud" {
    client {
        endpoint = "https://otlp-gateway-prod-abcxyz.grafana.net/otlp"
        auth     = otelcol.auth.basic.grafana_cloud.handler
    }
}

otelcol.auth.basic "grafana_cloud" {
    username = "0000000"
    password = "glc_foo="
}
```
Edit `.env` and paste the URL, username, and password into `GC_OTLP_URL`, `GC_OTLP_ACCOUNT`, and `GC_OTLP_KEY`. No quotes needed. Save the file.

You do **not** need to `export` these into your shell. Docker Compose automatically reads a file named `.env` from the directory you run it in and uses it to resolve the `${VAR}` placeholders in the compose files. The file persists across reboots and the values are picked up every time you run `docker compose`, so nothing leaks into your user environment and nothing is lost on logout. If you ever want to maintain side-by-side environments on one host (dev/staging/prod) you can keep additional files like `.env.prod` and select one at run time:
```
docker compose --env-file .env.prod -f compose-base.yaml -f compose-groups.generated.yaml up -d
```

#### Compose interpolation vs. per-service `env_file:`
There are two distinct mechanisms in Docker Compose for "loading variables from a file," and the distinction matters if you ever extend this setup:

- **Compose-level interpolation (what this repo uses)** — variables in `.env` are substituted into the compose file *at parse time*, before any container is created. They become whatever you reference them as (`environment:`, `command:`, ports, image tags, etc.). The container itself never sees `.env`; it only sees what you explicitly hand it via the `environment:` block.
- **Per-service `env_file:`** — adding `env_file: [.env]` to a service block does something different: it injects the file's contents *into that container's environment* at runtime. Use this when a container expects to read a variable it wasn't explicitly given via `environment:` — for example, a third-party image that auto-reads `MY_API_KEY` from `os.environ`. None of the containers in this repo need that, so we rely on interpolation alone, but it's worth knowing the difference if you swap in something new.

The `config.alloy` file is already wired to those env vars; you should not need to touch it unless you have non-ktranslate changes to make.

### Configure the SNMP credential groups
Each file in `groups/*.env` is one credential group. Open the file and fill in the values — every variable is documented inline in the sample. The important ones:

- **`GROUP`** — short identifier (`cisco`, `palo`, etc.). Used in container names, file paths, and the OTEL `service.name` so dashboards can split by group.
- **`SNMP_VERSION`** — `v2c` or `v3`. The other credential fields are only required for the matching version.
- **`DISCOVERY_SOURCE`** — where this group's device list comes from: `cidr` or `netbox` (defaults to `cidr` if unset).
- **`METALISTEN_PORT` / `TRAP_PORT`** — host ports for this group. Must be unique across groups and must not collide with the static services (9995, 9996, 9998, 4317, 12346, 1514). The generator will refuse to run if it finds a collision.

Depending on `DISCOVERY_SOURCE`, fill in one of the two variants:

**`DISCOVERY_SOURCE=cidr`** — ktranslate scans the addresses you list:
- **`TARGETS`** — comma-separated list of CIDRs or `/32` IPs for discovery to scan.

**`DISCOVERY_SOURCE=netbox`** — ktranslate queries NetBox and polls the devices that match your filters:
- **`NETBOX_TAG` / `NETBOX_SITE` / `NETBOX_LOCATION` / `NETBOX_TENANT`** — comma-separated; a device matching **any** listed value for the field qualifies.
- **`NETBOX_ROLE` / `NETBOX_STATUS`** — single value, matched exactly.
- A device must match **all** the non-empty filters above to be polled. Leave a field blank to drop it from the query; leaving **all** of them blank pulls every device in NetBox (the generator warns you when that happens).
- **`NETBOX_IP_TO_PICK`** — which IP to poll on each matched device: `primary` (the device's primary IP) or `oob` (out-of-band IP).
- NetBox groups also need shared credentials in `.env`: **`NETBOX_HOST`** and **`NETBOX_TOKEN`**. They're shared by every netbox group and only required if at least one group uses `DISCOVERY_SOURCE=netbox` — `preflight` fails if a netbox group exists but they're unset. Leave them blank for CIDR-only deployments.

When you're ready, render the configs:
```
make generate
```
This produces:
- `config/discovery-<group>.yaml` — the canonical discovery config the discovery script feeds to ktranslate
- `config/poller-<group>.yaml` — the polling config, with the `devices:` block pointing at `state/devices-<group>.yaml` via an `@`-include
- `compose-groups.generated.yaml` — service definitions for every group's poller and discovery container

All three are derived artifacts: they are regenerated from `groups/*.env` and the templates in `templates/` every time you run the script. **Don't hand-edit them.** If you need different rendering, edit the templates instead.

### Adding, removing, or modifying a group
Adding `groups/fortinet.env` is the whole change — no compose file edits, no script edits:
```
cp groups/cisco.env.sample groups/fortinet.env
# edit groups/fortinet.env: set GROUP=fortinet, fill creds, assign unique ports
make generate
make up
make discover GROUP=fortinet
```
`make up` is idempotent — it starts the new services without disturbing the existing ones. Modifying or removing a group follows the same pattern (edit or delete the env file, re-run `make generate`, re-run `make up`).

### Permissions
The discovery script writes files into `state/` that the containers need to be able to read. Set ownership once:
```
sudo chown -R 1000:1000 config/ state/
```

### Running it
There's a small Makefile wrapping the common operations:
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
`make up` is idempotent — it'll start newly-added services without disturbing running ones. The pollers begin polling whatever devices are in their respective `state/devices-<group>.yaml`; until you've run discovery, those are empty stubs (`{}`) and no SNMP traffic actually goes out. Run `make discover GROUP=cisco` (and the same for each group) to populate them.

On each `make up`, `scripts/compute-limits.sh` reads the host's available memory and writes `compose-limits.generated.yaml` with per-container caps. Docker Compose has no project-wide memory budget — each service gets its own limit — but the script sizes caps so their sum stays within a configurable fraction of available RAM. SNMP pollers receive the largest share, capped at **4G each**, which matches a typical **4 vCPU / 8 GiB** trial host running one poller plus alloy, flow, and syslog. Preview the plan without restarting with `make limits-show`.

Optional `.env` tuning (see `.env.sample`):
- `KTRANS_HOST` — identifies which host this stack runs on; tags all telemetry and suffixes each `service.name`. Leave blank to auto-use the machine's hostname. See [Telling multiple deployments apart](#telling-multiple-deployments-apart).
- `KTRANSLATE_IMAGE` / `ALLOY_IMAGE` — leave blank for `:latest`, or pin e.g. `quay.io/kentik/ktranslate:v2.2.37` / `grafana/alloy:v1.8.3`. After changing a pin, `docker compose pull` and recreate.
- `MEM_BUDGET_FRACTION=0.80` — fraction of `MemAvailable` allocated across the stack
- `MEM_SNMP_MAX=4g` — per-poller ceiling (default 4g)
- `MEM_SNMP_LIMIT=4g` — hard override for every SNMP poller (skip auto math)
- `MEM_LIMITS=off` — disable limits entirely

If you'd rather skip the Makefile, the equivalent raw commands are:
```
./scripts/preflight.sh
./scripts/generate-groups.sh
echo '{}' | tee state/devices-cisco.yaml state/devices-palo.yaml   # bootstrap
./scripts/compute-limits.sh
docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-limits.generated.yaml up -d
./scripts/run-discovery.sh cisco
```
The `discover_*` services are gated behind a Compose profile so `up` does not start them — they only run when invoked via `make discover` or `./scripts/run-discovery.sh`.

#### Optional: instant flow data with the sflow demo overlay
If you want to see flow data immediately, before any real router or switch is exporting netflow/sflow, there's an optional overlay (`compose-sflow.yaml`) that runs `host-sflow` on the Docker host and points it at the `ktranslate_flow` container. Enable it with:
```
make detect-net   # auto-fills HOST_NET in .env with the host's default interface
make up-demo      # same as 'make up' but layers compose-sflow.yaml on top
```
`make up` does **not** include this overlay — it's off by default. `host-sflow` needs the host's primary interface set as `HOST_NET` in `.env`; `make detect-net` fills that in for you (it defaults to `ens4` otherwise). Once you have real flow sources pointed at UDP/9995 you can drop the overlay and go back to `make up`.

### Schedule ongoing discovery
Add cron entries on the host so new devices get picked up automatically. Stagger each group a few minutes apart so they don't all run at once:
```
0  */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh cisco >> /var/log/ktrans-discovery.log 2>&1
5  */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh palo  >> /var/log/ktrans-discovery.log 2>&1
```
Each run scans the group's configured CIDRs (or queries NetBox, depending on its `DISCOVERY_SOURCE`), atomically publishes a fresh `state/devices-<group>.yaml`, and sends `SIGUSR2` to the matching poller so it picks up the new device list without a restart. (`SIGUSR2` is ktranslate's reload signal — `SIGHUP` has no handler and would terminate the container.) If discovery returns zero devices (network blip, container crash) the script preserves the previous device list rather than wiping it. If the device list is unchanged from the previous run, no reload is sent.

## Telling multiple deployments apart
If you run this stack on more than one host (e.g. one per site or datacenter), every signal can be tagged with which host produced it so the two never get mixed up in Grafana. A single variable, `KTRANS_HOST`, controls this:

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

## Data in Grafana
Within a couple minutes of seeing ktranslate polling your devices there should be data in your Grafana Cloud's default Prometheus data source. Metrics start with `kentik_snmp_*` and carry labels like `device_name` and `if_interface_name` based on the SNMP profile assigned during discovery. Each poller stamps its own `service.name` (`ktranslate-snmp-cisco`, `ktranslate-snmp-palo`, etc. — plus a `-<host>` suffix when `KTRANS_HOST` is set) so you can split dashboards by credential group, and by host across multiple deployments.

### Quick verification
Open Grafana Cloud → Explore → your default Prometheus data source, and paste this:
```
count by (device_name, service_name) (kentik_snmp_DeviceMetrics)
```
You should get one row per polled device, grouped by which credential group is polling it. If the table is empty after a couple minutes, check `make logs` for discovery activity and confirm `snmpwalk` works from the Docker host to one of your devices (see `troubleshooting/snmp.md`).

Network gear cardinality is all over the place — a UPS might emit ~50 active series, a large core switch or load balancer might emit 10,000. Plan accordingly.

Each SNMP poller stamps its `service.name` resource attribute as `ktranslate-snmp-<group>` (e.g. `ktranslate-snmp-cisco`), so the per-group split is visible in any Grafana query that groups by `service_name`. Discovery containers use `ktranslate-discover-<group>` for the same reason — they're distinguishable in logs without polluting the SNMP poller's data. When `KTRANS_HOST` is set (or auto-detected — see [Telling multiple deployments apart](#telling-multiple-deployments-apart)), a `-<host>` suffix is appended to each of these, e.g. `ktranslate-snmp-cisco-site-a`.

Flow data is high volume, so the `ktranslate_flow` container uses the `--rollups` argument in `compose-base.yaml` to convert raw flow records into a smaller collection of metric series. This is far more cost-effective to store and query than raw flow log lines. The [Sankey panel](https://grafana.com/grafana/plugins/netsage-sankey-panel/) in Grafana works well to visualize this data after applying the `Group by` transformation to sum bytes.

Two flags govern the cardinality ceiling for the flow metric:
- **`--rollup_interval=60`** — emit one batch of rolled-up series every 60 seconds.
- **`--rollup_top_k=100`** — only emit the top 100 series (by aggregated value) in each batch.

Active-series math: `max ≤ rollup_top_k × (active_series_window / rollup_interval)`. With Grafana Cloud's typical 20-minute active-series window: `100 × (1200 / 60) = 2,000 series` as the worst-case ceiling. In practice traffic patterns are sticky, so steady state is usually a fraction of that.

### Compatibility with the official Grafana Cloud netflow integration
The flow pipeline in this repo is aligned with the [official Grafana Cloud ktranslate-netflow integration](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/integrations/integration-reference/integration-ktranslate-netflow/) — `config.alloy.sample` includes an `otelcol.processor.transform "preprocessing"` block that renames `kentik.rollup.bytes_by_flow` to `network.io.by_flow` and remaps the flow attributes (`src_addr`, `dst_addr`, `dst_port`, etc.) to OTEL semantic-convention names like `network.local.address` and `network.peer.port`. The flow container's data also gets `service.name=integrations/ktranslate-netflow` so it shows up under that name in Grafana.

What this means in practice:
- You can import the **Netflow overview** dashboard from the official integration page and it will light up against this pipeline.
- The bundled `dashboards/Ktranslate Flow Summary.json` has been updated to query the new OTEL semconv metric and label names.
- SNMP and discovery containers set their own `OTEL_SERVICE_NAME` (`ktranslate-snmp-<group>` / `ktranslate-discover-<group>`, plus the `-<host>` suffix when `KTRANS_HOST` is set) so the preprocessing transform's `service.name` rewrite skips them.

### Dashboards, alerts, and skills
The repo ships a fuller set of assets to get you started:

- **`dashboards/`** — importable JSON dashboards: `00 Network Device Summary`, `01 Network Device Details`, `02 Network Flow Summary`, `03 Ktranslate Architecture & Datacenter Replication`, plus `Ktranslate Flow Summary`, `ktranslate network fleet overview`, and `ktranslate snmp device view`. Import whichever you want into your Grafana instance.
- **`alerts/`** — example alert rules, a contact point, and a notification template you can adapt to your own alerting.
- **`skills/`** — guides for network dashboard design and onboarding new hardware.

# Contact me
Feel free to reach out via Issues and PRs in this repo or contact me directly, marcnetterfield@gmail.com
