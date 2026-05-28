# KtransToGrafana
This repo is an example of a quick time to value deployment of [Ktranslate](https://github.com/kentik/ktranslate/) writing to a [Grafana Cloud](https://grafana.com/products/cloud/) OTLP endpoint. While there are countless approaches to accomplish this I am hoping to provide a simple, functional example without requiring too much Linux or Alloy expertise. You should be able to have SNMP data showing up in your Grafana account in about 10-15 minutes.

This repo is not maintained by Kentik or Grafana, it is just a demonstration of how to easily connect the two tools together. Questions about the example configs can be raised at this repo, bugs or feature requests for either tool should be directed at their respective repos.

If you run into problems you can check the ```troubleshooting``` folder in this repo for some more help.

## Deployment models
This repo has three branches, each demonstrating a different operational shape:

- **[`main`](../../tree/main)** — single SNMP poller, single credential set, CIDR-based discovery. Fastest path to data in Grafana; best for proof-of-concept or single-vendor environments.
- **[`multicontainer_example`](../../tree/multicontainer_example)** — one poller per credential group, declarative `groups/<name>.env` files, generator-driven configs. Use this when you have multiple SNMP credential sets (different vendors, sites, etc.) to keep separate.
- **[`multicontainer_netbox`](../../tree/multicontainer_netbox)** — same as `multicontainer_example` but the device list comes from NetBox (filtered by tag/role/site/etc.) instead of CIDR scanning. Use this when NetBox is your source of truth for what exists on the network.

**You are reading the `multicontainer_example` branch.**

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

### Copy the sample files
The base files (env + Alloy) are one-time copies:
```
cp .env.sample .env
cp config.alloy.sample config.alloy
```
The credential groups are managed under `groups/`. Two sample groups ship in the repo — copy whichever you want as a starting point, or both:
```
cp groups/cisco.env.sample groups/cisco.env
cp groups/palo.env.sample  groups/palo.env
```
You can delete either of these if you only need one, and you can copy additional sample files to define more groups (e.g. `cp groups/cisco.env.sample groups/fortinet.env`). The generator picks up everything matching `groups/*.env`.

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
- **`TARGETS`** — comma-separated list of CIDRs or `/32` IPs for discovery to scan.
- **`METALISTEN_PORT` / `TRAP_PORT`** — host ports for this group. Must be unique across groups and must not collide with the static services (9995, 9996, 9998, 4317, 12346, 1514). The generator will refuse to run if it finds a collision.

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
make up                     # runs preflight + bootstrap, then docker compose up -d
make logs                   # tail logs from all containers
make down                   # stop and remove the stack
make discover GROUP=cisco   # one-shot discovery for one group; populates state/devices-cisco.yaml
```
`make up` is idempotent — it'll start newly-added services without disturbing running ones. The pollers begin polling whatever devices are in their respective `state/devices-<group>.yaml`; until you've run discovery, those are empty stubs (`{}`) and no SNMP traffic actually goes out. Run `make discover GROUP=cisco` (and the same for each group) to populate them.

If you'd rather skip the Makefile, the equivalent raw commands are:
```
./scripts/preflight.sh
./scripts/generate-groups.sh
echo '{}' | tee state/devices-cisco.yaml state/devices-palo.yaml   # bootstrap
docker compose -f compose-base.yaml -f compose-groups.generated.yaml up -d
./scripts/run-discovery.sh cisco
```
The `discover_*` services are gated behind a Compose profile so `up` does not start them — they only run when invoked via `make discover` or `./scripts/run-discovery.sh`.

### Schedule ongoing discovery
Add cron entries on the host so new devices get picked up automatically. Stagger each group a few minutes apart so they don't all run at once:
```
0  */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh cisco >> /var/log/ktrans-discovery.log 2>&1
5  */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh palo  >> /var/log/ktrans-discovery.log 2>&1
```
Each run scans the configured CIDRs, atomically publishes a fresh `state/devices-<group>.yaml`, and sends a SIGHUP to the matching poller so it picks up the new device list without a restart. If discovery returns zero devices (network blip, container crash) the script preserves the previous device list rather than wiping it. If the device list is unchanged from the previous run, no reload is sent.

## Data in Grafana
Within a couple minutes of seeing ktranslate polling your devices there should be data in your Grafana Cloud's default Prometheus data source. Metrics start with `kentik_snmp_*` and carry labels like `device_name` and `if_interface_name` based on the SNMP profile assigned during discovery. Each poller stamps its own `service.name` (`snmp-cisco`, `snmp-palo`, etc.) so you can split dashboards by credential group.

### Quick verification
Open Grafana Cloud → Explore → your default Prometheus data source, and paste this:
```
count by (device_name, service_name) (kentik_snmp_DeviceMetrics)
```
You should get one row per polled device, grouped by which credential group is polling it. If the table is empty after a couple minutes, check `make logs` for discovery activity and confirm `snmpwalk` works from the Docker host to one of your devices (see `troubleshooting/snmp.md`).

Network gear cardinality is all over the place — a UPS might emit ~50 active series, a large core switch or load balancer might emit 10,000. Plan accordingly.

Each SNMP poller stamps its `service.name` resource attribute as `ktranslate-snmp-<group>` (e.g. `ktranslate-snmp-cisco`), so the per-group split is visible in any Grafana query that groups by `service_name`. Discovery containers use `ktranslate-discover-<group>` for the same reason — they're distinguishable in logs without polluting the SNMP poller's data.

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
- SNMP and discovery containers set their own `OTEL_SERVICE_NAME` (`ktranslate-snmp-<group>` / `ktranslate-discover-<group>`) so the preprocessing transform's `service.name` rewrite skips them.

JSON for example dashboards (flow summary, fleet overview, device view) is in the `dashboards/` folder — import them into your Grafana instance to get started.

# Contact me
Feel free to reach out via Issues and PRs in this repo or contact me directly, marcnetterfield@gmail.com
