# KtransToGrafana
This repo is an example of a quick time to value deployment of [Ktranslate](https://github.com/kentik/ktranslate/) writing to a [Grafana Cloud](https://grafana.com/products/cloud/) OTLP endpoint. While there are countless approaches to accomplish this I am hoping to provide a simple, functional example without requiring too much Linux or Alloy expertise. You should be able to have SNMP data showing up in your Grafana account in about 5 minutes, 10 if you get really jammed up on Vim.

This repo is not maintained by Kentik or Grafana, it is just a demonstration of how to easily connect the two tools together.  Questions about the example configs can be raised at this repo, bugs or feature requests for either tool should be directed at their respective repos.

If you run into problems you can check the ```troubleshooting``` folder in this repo for some more help.

## Deployment models
This repo has three branches, each demonstrating a different operational shape:

- **[`main`](../../tree/main)** — single SNMP poller, single credential set, CIDR-based discovery. Fastest path to data in Grafana; best for proof-of-concept or single-vendor environments.
- **[`multicontainer_example`](../../tree/multicontainer_example)** — one poller per credential group, declarative `groups/<name>.env` files, generator-driven configs. Use this when you have multiple SNMP credential sets (different vendors, sites, etc.) to keep separate.
- **[`multicontainer_netbox`](../../tree/multicontainer_netbox)** — same as `multicontainer_example` but the device list comes from NetBox (filtered by tag/role/site/etc.) instead of CIDR scanning. Use this when NetBox is your source of truth for what exists on the network.

**You are reading the `main` branch.**

## Architecture
This example will provide you with a docker compose configuration to launch 3 containers; one running Ktranslate for receiving netflow data (supports the most common formats such as netflow 5/9/sflow/ipfix/nbar/pan/etc), another running Ktranslate to do SNMP device discovery and polling, and another running a stripped down Grafana Alloy agent to forward OTLP data from the previous containers. 
Feel free to fork this repo or PR changes if you find that we can make this more simple or more 'production-ready' 

![Architecture](./ktrans_architecture.png)
![Detail](./ktrans_to_alloy.png)

## Usage Instructions
Start with an Ubuntu Linux system (also tested under Windows WSL).

Install Docker and Docker Compose as per their [documentation](https://docs.docker.com/compose/install/linux/#install-using-the-repository)
Run the following to ensure this is completed successfully
```docker engine
docker run hello-world
```
and
```docker compose
docker compose version
```

Make sure you are in the correct directory where you intend to store all the relevant files for ktranslate

```
pwd
```

Clone this repo or your fork into the folder
```
git clone https://github.com/Mesverrum/KtransToGrafana.git
cd KtransToGrafana/
```

There are 3 .sample files in here that you will need to copy and modify to your requirements
```
cp .env.sample .env
cp snmp.yaml.sample snmp.yaml
cp config.alloy.sample config.alloy
```

### ENV variables
Setting up the .env file is the first step. Log in to your Grafana Cloud account and search for `Add new connection` then in that screen search for `otlp`, and select the `OpenTelemetry` tile. 
Create a new token or use an existing one. 
In this case you can skip over the instructions for installing Alloy and go straight to `Append the generated configuration to your configuration file` and scroll to the bottomr to find the pieces you will need to pass into  container. You should grab the URL of the client endpoint from the `otelcol.exporter.otlphttp` section and the username/password from the `otelcol.auth.basic` section.  

**You do not need to deploy any collector at this time, we just want to copy out the credentials for our environmental variables.**

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

In your terminal edit the `.env` file
```
vim .env
```

Switch to INSERT mode by pressing `i` on your keyboard and remove the placeholders and paste in the values you got from your Grafana Cloud web console to set the correct values for the below variables, you do not need quotes.

GC_OTLP_URL

GC_OTLP_ACCOUNT

GC_OTLP_KEY


When you have all 3 populated then press `Esc` and type `:wq` to save the changes and exit Vim.

You do **not** need to `export` these into your shell. Docker Compose automatically reads a file named `.env` from the directory you run it in and uses it to resolve the `${VAR}` placeholders in `compose.yaml`. The file persists across reboots and the values are picked up every time you run `docker compose`, so nothing leaks into your user environment and nothing is lost on logout. If you ever want to maintain side-by-side environments on one host (dev/staging/prod) you can keep additional files like `.env.prod` and select one at run time:
```
docker compose --env-file .env.prod up -d
```

#### Compose interpolation vs. per-service `env_file:`
There are two distinct mechanisms in Docker Compose for "loading variables from a file," and the distinction matters if you ever extend this setup:

- **Compose-level interpolation (what this repo uses)** — variables in `.env` are substituted into the compose file *at parse time*, before any container is created. They become whatever you reference them as (`environment:`, `command:`, ports, image tags, etc.). The container itself never sees `.env`; it only sees what you explicitly hand it via the `environment:` block.
- **Per-service `env_file:`** — adding `env_file: [.env]` to a service block does something different: it injects the file's contents *into that container's environment* at runtime. Use this when a container expects to read a variable it wasn't explicitly given via `environment:` — for example, a third-party image that auto-reads `MY_API_KEY` from `os.environ`. None of the containers in this repo need that, so we rely on interpolation alone, but it's worth knowing the difference if you swap in something new.

The `config.alloy` file is already configured to use those ENV variables, so there should not be a need to modify this file unless you have modifications to make that are unrelated to ktranslate.

#### host-sflow interface
The `host-sflow` service in `compose.yaml` needs to know which interface to listen on. It reads `HOST_NET` from `.env` and falls back to `ens4` if unset. The shipped `.env.sample` includes `HOST_NET=ens4` as a placeholder — overwrite it with your host's real interface either by hand, or with:
```
make detect-net
```
which is equivalent to:
```
echo "HOST_NET=$(ip -4 route show default | awk '/^default/ {print $5; exit}')" >> .env
```
Both walk the IPv4 routing table for the default route and append the matching interface name. If you already have other flow sources and don't need host-sflow, you can remove that service from `compose.yaml` instead.

### snmp.yaml
The last piece to modify is the `snmp.yaml` file. This file manages the config of the Ktranslate container that is used to poll SNMP devices. The [documentation](https://github.com/kentik/ktranslate/wiki) on this in the main project Github is a little sparse right now, but more detailed documentation on the many options can be found [here](https://docs.newrelic.com/docs/network-performance-monitoring/advanced/advanced-config/). Grafana and OTEL specific documentation will be added in the coming months.

For the sake of a quick example you can open the `snmp.yaml` file in Vim and press `i` to go into `INSERT` mode to make changes. The first section is discovery where you can set the CIDR IP ranges for SNMP enabled devices you want to run a discovery against. For specific devices you can enter their IP with /32 at the end.  
The `default_communities` section can hold a list of SNMP v2 community strings to test against the devices.  

For SNMP v3 I would recommend adding an "other_v3s" block like this inside the discovery block
```
discovery:
  other_v3s:
  - user_name: my_user_1
    authentication_protocol: my_auth_protocol_1
    authentication_passphrase: my_auth_pass_1
    privacy_protocol: my_priv_protocol_1
    privacy_passphrase: my_priv_pass_1
    context_engine_id: ""
    context_name: ""
  - user_name: my_user_2
    authentication_protocol: my_auth_protocol_2
    authentication_passphrase: my_auth_pass_2
    privacy_protocol: my_priv_protocol_2
    privacy_passphrase: my_priv_pass_2
    context_engine_id: ""
    context_name: ""
```

The `devices` section will be blank initially, but as the discovery runs the container will update this file with the information of devices that it has connected with. This forms the target list that ktranslate will use after the discovery job is complete to poll the devices. When Ktranslate discovers a device it will collect the SysObjectID and based on that it does a lookup against the library of device profiles found in this repo [https://github.com/kentik/snmp-profiles](https://github.com/kentik/snmp-profiles).
The profile repo contains a curated list of OIDs to collect that should provide useful information. This eliminates the pain of hunting down MIBs and processing them through the generator and then cleaning up the resulting output.

Once you have your CIDR and credentials set you can press `Esc` and type in `:wq` to save your changes.

### Set file ownership
The ktranslate container runs as UID 1000 and needs to be able to mutate `snmp.yaml` in place when discovery finds a new device. Run this once before starting the stack:
```
sudo chown 1000:1000 snmp.yaml
```

### Running it
With your variables set and your target CIDR subnets in place you can now run the containers. There's a small Makefile to wrap the common operations:
```
make preflight    # check that .env / snmp.yaml / config.alloy are ready and Grafana creds are filled in
make up           # runs preflight, then docker compose up -d
make logs         # tail logs from all containers
make down         # stop and remove the stack
```
If you'd rather skip the Makefile, the equivalent raw commands work too:
```
./scripts/preflight.sh
docker compose up -d
```
You will see the latest container images get downloaded and as long as we did no introduce any syntax errors you should see ktranslate importing the collection of profiles and begin discovery. If you have a reasonable range of subnets this should only take a minute or two and then you will see devices being mapped to profiles and the relevant OIDs start getting polled. If you don't see any major errors you can return to your terminal session by pressing `CTRL+Z` (unless you are using vscode and it is intercepting the key combo...)


## Data in Grafana

Within a couple minutes of seeing Ktranslate polling your devices there should be data in your Grafana Cloud's default Prometheus data source. The metrics will have names that start with `kentik_snmp_*` and have relevant labels such as `device_name` and `if_interface_name` based on the SNMP profile that this model was associated with. Network gear is all over the place in terms of cardinality, so most people tend to figure you will collect about 1,000 active series per network device, but in practice something simple like a UPS might create 50 AS and a large core switch or load balancer might have 10,000.

### Quick verification
Open Grafana Cloud → Explore → your default Prometheus data source, and paste this:
```
count by (device_name) (kentik_snmp_DeviceMetrics)
```
You should get one row per device ktranslate is currently polling. If the table is empty after a couple minutes, check `docker compose logs ktranslate_snmp` for discovery activity, and confirm `snmpwalk` works from the Docker host to one of your devices (see `troubleshooting/snmp.md`).

Because flow data is so high-volume in its raw form, this configuration has Ktranslate aggregating it into a small set of metric series using the `--rollups` argument in `compose.yaml`. This is much cheaper to store and query than raw flow log lines. The [Sankey panel](https://grafana.com/grafana/plugins/netsage-sankey-panel/) in Grafana works well to visualize the result after applying a `Group by` transformation to sum bytes.

Two flags govern the cardinality ceiling for the flow metric:
- **`--rollup_interval=60`** — emit one batch of rolled-up series every 60 seconds.
- **`--rollup_top_k=100`** — only emit the top 100 series (by aggregated value) in each batch.

Active-series math:
```
max_active_series ≤ rollup_top_k × (active_series_window / rollup_interval)
```
With Grafana Cloud's typical 20-minute active-series window: `100 × (1200 / 60) = 2,000 series` as the worst-case ceiling. In practice traffic patterns are sticky — the busiest src/dst/port combinations recur across consecutive intervals — so steady state is usually a fraction of the ceiling. If you raise `--rollup_top_k` the ceiling scales linearly; the staleness window in your Grafana Cloud tier might also differ (check whether it's 5, 20, or 30 minutes for your stack and recompute accordingly).

### Compatibility with the official Grafana Cloud netflow integration
The flow pipeline in this repo is aligned with the [official Grafana Cloud ktranslate-netflow integration](https://grafana.com/docs/grafana-cloud/monitor-infrastructure/integrations/integration-reference/integration-ktranslate-netflow/) — `config.alloy.sample` includes an `otelcol.processor.transform "preprocessing"` block that renames `kentik.rollup.bytes_by_flow` to `network.io.by_flow` and remaps the flow attributes (`src_addr`, `dst_addr`, `dst_port`, etc.) to OTEL semantic-convention names like `network.local.address` and `network.peer.port`. The flow container's data also gets `service.name=integrations/ktranslate-netflow` so it shows up under that name in Grafana.

What this means in practice:
- You can import the **Netflow overview** dashboard from the official integration page and it will light up against this pipeline.
- The bundled `dashboards/Ktranslate Flow Summary.json` was authored against the old `kentik.rollup.*` names and will need its queries updated (or replaced with the official dashboard).
- SNMP and syslog telemetry is untouched — those containers set their own `OTEL_SERVICE_NAME` (`ktranslate-snmp` / `ktranslate-syslog`) so the preprocessing transform's `service.name` rewrite skips them.

The quick-verification PromQL for flow:
```
sum by (device_name) (rate(network_io_by_flow[5m]))
```

# Contact me
Feel free to reach out to me via Issues and PR's in this repo or contact me directly, marcnetterfield@gmail.com
