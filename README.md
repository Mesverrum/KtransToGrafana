# KtransToGrafana
This repo is an example of a quick time to value deployment of [Ktranslate](https://github.com/kentik/ktranslate/) writing to a [Grafana Cloud](https://grafana.com/products/cloud/) OTLP endpoint. While there are countless approaches to accomplish this I am hoping to provide a simple, functional example without requiring too much Linux or Alloy expertise. You should be able to have SNMP data showing up in your Grafana account in about 10-15 minutes.

This repo is not maintained by Kentik or Grafana, it is just a demonstration of how to easily connect the two tools together. Questions about the example configs can be raised at this repo, bugs or feature requests for either tool should be directed at their respective repos.

If you run into problems you can check the ```troubleshooting``` folder in this repo for some more help.

## Architecture
This example deploys a small set of containers via Docker Compose:
- **`ktranslate_flow`** — receives netflow data (netflow 5/9, sflow, ipfix, nbar, pan, etc.) and converts it to OTEL metrics via configurable rollups.
- **`ktranslate_snmp_cisco`** and **`ktranslate_snmp_palo`** — long-running SNMP pollers, one per credential group. Each reads a static config file from `config/` plus a separately-managed device list from `state/`.
- **`discover_cisco`** and **`discover_palo`** — short-lived discovery containers, one per credential group. Run on a schedule, write discovered devices back to `state/`, and signal the matching poller to reload.
- **`ktranslate_syslog`** — collects syslog and forwards as OTEL logs.
- **`alloy`** — a stripped-down Grafana Alloy agent that forwards all OTLP traffic from the above to Grafana Cloud.

The split between discovery and polling lets git stay the source of truth for credentials, scan ranges, and polling rules, while letting the network itself be the source of truth for which devices currently exist. Discovery writes are atomic and reversible; polling configs are mounted read-only and never mutated.

![Architecture](./ktrans_architecture.png)
![Detail](./ktrans_to_alloy.png)

## Usage Instructions

### Prerequisites
Start with an Ubuntu Linux system (also tested under Windows WSL).

Install Docker and Docker Compose per their [documentation](https://docs.docker.com/compose/install/linux/#install-using-the-repository), and `yq` (Mike Farah's version) for the discovery script:
```
sudo apt install yq
```
Verify everything is in place:
```
docker run hello-world
docker compose version
yq --version
```

Clone this repo into the directory where you intend to store your ktranslate deployment:
```
git clone https://github.com/Mesverrum/KtransToGrafana.git
cd KtransToGrafana/
```

### Copy the sample files
There are six `.sample` files to copy and edit. The four `config/` files are your *intent* (credentials, what to scan, polling rules) and are read by ktranslate at runtime. The `.env` and `config.alloy` are for environmental variables and the Alloy forwarder respectively.
```
cp .env.sample .env
cp config.alloy.sample config.alloy
cp config/discovery-cisco.yaml.sample config/discovery-cisco.yaml
cp config/discovery-palo.yaml.sample   config/discovery-palo.yaml
cp config/poller-cisco.yaml.sample     config/poller-cisco.yaml
cp config/poller-palo.yaml.sample      config/poller-palo.yaml
```

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
Edit `.env` and paste the URL, username, and password into `GC_OTLP_URL`, `GC_OTLP_ACCOUNT`, and `GC_OTLP_KEY`. No quotes needed. Save, then load them into your shell:
```
export $(xargs < .env)
echo $GC_OTLP_URL
```
These exports are session-scoped — disconnecting or rebooting loses them. Make them persistent however suits your environment (systemd unit env file, `/etc/environment`, etc.) if you want survival across reboots.

The `config.alloy` file is already wired to those env vars; you should not need to touch it unless you have non-ktranslate changes to make.

### Configure the SNMP credential groups
The repo ships with two credential groups out of the box: `cisco` (SNMPv3) and `palo` (SNMPv2c). Each group has two files:

- `config/discovery-<group>.yaml` — used by the short-lived discovery container. Lists CIDRs/IPs to scan and the credential to use. **Discovery may mutate a runtime copy of this file, but never the file in `config/` itself** — the script seeds a fresh copy from `config/` on every run, so this file in git is always canonical.
- `config/poller-<group>.yaml` — used by the long-running poller. Holds the same credential (so the poller can authenticate to discovered devices) plus polling-rate settings. The `devices:` block uses a `@-include` to pull the device list from `state/devices-<group>.yaml`, which the discovery script publishes.

Edit each `config/discovery-*.yaml` and `config/poller-*.yaml` to put in your real CIDRs (or `/32` entries for an explicit device list) and your real credentials. The credential in the poller config **must match** the discovery config for the same group, or the poller won't be able to authenticate.

For SNMPv3 (used by the Cisco example) fill in the `default_v3:` block. For SNMPv2c (used by the Palo example) put your community string in `default_communities:`. To add a third credential group (e.g. Fortinet), copy a pair of the `.sample` files, add a `discover_fortinet` and `ktranslate_snmp_fortinet` service to `compose-discovery.yaml` on a unique port pair, and you're done.

### Permissions
The discovery script writes files into `state/` that the container needs to be able to read. Set ownership once:
```
sudo chown -R 1000:1000 config/ state/
```

### Bootstrap the device lists
The pollers `@-include` `state/devices-<group>.yaml`, so those files must exist before the pollers start. Either run a discovery cycle first:
```
./scripts/run-discovery.sh cisco
./scripts/run-discovery.sh palo
```
Or seed empty stubs:
```
echo '{}' | tee state/devices-cisco.yaml state/devices-palo.yaml
```

### Start everything
```
docker compose -f compose-discovery.yaml up -d
```
You'll see images get pulled, then the pollers will start and begin polling whatever devices are in their respective `state/devices-*.yaml`. The `discover_*` services are gated behind a Compose profile so `up` does not start them — they only run when invoked via the discovery script.

### Schedule ongoing discovery
Add cron entries on the host so new devices get picked up automatically:
```
0 */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh cisco >> /var/log/ktrans-discovery.log 2>&1
30 */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh palo  >> /var/log/ktrans-discovery.log 2>&1
```
Each run will scan the configured CIDRs, atomically publish a fresh `state/devices-<group>.yaml`, and send a SIGHUP to the matching poller so it picks up the new device list without a restart. If discovery returns zero devices (network blip, container crash) the script preserves the previous device list rather than wiping it. If the device list is unchanged from the previous run, no reload is sent.

## Data in Grafana
Within a couple minutes of seeing ktranslate polling your devices there should be data in your Grafana Cloud's default Prometheus data source. Metrics start with `kentik_snmp_*` and carry labels like `device_name` and `if_interface_name` based on the SNMP profile assigned during discovery. Each poller stamps its own `service.name` (`snmp-cisco`, `snmp-palo`) so you can split dashboards by credential group.

Network gear cardinality is all over the place — a UPS might emit ~50 active series, a large core switch or load balancer might emit 10,000. Plan accordingly.

Flow data is high volume, so the `ktranslate_flow` container uses the `--rollups` argument in `compose-discovery.yaml` to convert raw flow records into a smaller collection of metric series. This is far more cost-effective to store and query than raw flow log lines. The [Sankey panel](https://grafana.com/grafana/plugins/netsage-sankey-panel/) in Grafana works well to visualize this data after applying the `Group by` transformation to sum bytes.

JSON for example dashboards (flow summary, fleet overview, device view) is in the `dashboards/` folder — import them into your Grafana instance to get started.

# Contact me
Feel free to reach out via Issues and PRs in this repo or contact me directly, marcnetterfield@gmail.com
