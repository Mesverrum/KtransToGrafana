# Configuring credential groups

[← back to README](../README.md)

Each file in `groups/*.env` is one credential group. The [quickstart](../README.md#quickstart--onboard-your-devices-in-about-15-minutes) walks through onboarding a range with candidate credentials; this doc covers multiple groups, both discovery sources, and the credential options in depth.

Three sample groups ship in the repo — copy whichever fit your environment:

```
cp groups/single.env.sample groups/single.env   # minimal single-device CIDR group
cp groups/cisco.env.sample  groups/cisco.env     # CIDR discovery, SNMP v3 example
cp groups/palo.env.sample   groups/palo.env      # NetBox discovery, SNMP v2c example
```

Copy only the ones you need, and copy additional sample files to define more groups (e.g. `cp groups/cisco.env.sample groups/fortinet.env`). The generator picks up everything matching `groups/*.env`.

## Common fields

Every variable is documented inline in the sample. The important ones:

- **`GROUP`** — short identifier (`cisco`, `palo`, etc.). Used in container names, file paths, the OTEL `service.name` (a label identifying which collector produced the data), and stamped on every SNMP metric via `global.user_tags.snmp_group` in the generated poller config. In Grafana Explore the label appears as **`tags_snmp_group`** (OTLP export); dashboard variable **`$snmp_group`** filters with `tags_snmp_group=~"$snmp_group"`. Prefer that over `service_name` when filtering fleet dashboards by credential group — `service_name` also varies with `KTRANS_HOST` when you run multiple deployments.
- **`SNMP_VERSION`** — `v2c`, `v3`, or `mixed`. The other credential fields are only required for the matching version; `mixed` lets one group carry both v2c and v3 candidates (see [Multiple candidate credentials](#multiple-candidate-credentials-unknown-mapping)).
- **`DISCOVERY_SOURCE`** — where this group's device list comes from: `cidr` or `netbox` (defaults to `cidr` if unset).
- **`METALISTEN_PORT` / `TRAP_PORT`** — host ports for this group. Must be unique across groups and must not collide with the static services (9995, 9996, 9998, 4317, 12346, 1514). The generator refuses to run if it finds a collision.

### `snmp_group` on metrics

Each poller's generated `config/poller-<group>.yaml` sets:

```yaml
global:
  user_tags:
    snmp_group: <GROUP>
```

ktranslate copies `global.user_tags` onto every SNMP series from that poller. When metrics are exported via **OTLP** to Grafana Cloud (the default in this stack), the label appears as **`tags_snmp_group`** on series — the dashboard variable is still named `$snmp_group`, but PromQL filters use `tags_snmp_group=~"$snmp_group"`. After discovery, verify in Grafana Explore:

```
count by (tags_snmp_group, device_name) (kentik_snmp_PollingHealth)
```

You should see one `tags_snmp_group` value per credential group (`cisco`, `palo`, …). The bundled dashboards (`01`–`04`) expose a **`$snmp_group`** template variable. Flow and syslog receivers use a shared catalog with `user_tags: {}` — flow metrics are not tagged with `tags_snmp_group`; use `device_name` or flow attributes instead.

For site- or region-scoped groups, give each group a distinct `GROUP` name (e.g. `hq`, `branch1`) and unique ports — one poller per group. Deeper inventory attributes (site, role, tenant) belong in NetBox/CMDB enrichment later; `snmp_group` is intentionally just the credential-group key.

## Discovery source: `cidr`

ktranslate scans the addresses you list:

- **`TARGETS`** — comma-separated list of CIDRs or `/32` IPs for discovery to scan.

## Discovery source: `netbox`

ktranslate queries NetBox and polls the devices that match your filters:

- **`NETBOX_TAG` / `NETBOX_SITE` / `NETBOX_LOCATION` / `NETBOX_TENANT`** — comma-separated; a device matching **any** listed value for the field qualifies.
- **`NETBOX_ROLE` / `NETBOX_STATUS`** — single value, matched exactly.
- A device must match **all** the non-empty filters above to be polled. Leave a field blank to drop it from the query; leaving **all** of them blank pulls every device in NetBox (the generator warns you when that happens).
- **`NETBOX_IP_TO_PICK`** — which IP to poll on each matched device: `primary` (the device's primary IP) or `oob` (out-of-band IP).

NetBox groups also need shared credentials in `.env`: **`NETBOX_HOST`** and **`NETBOX_TOKEN`**. They're shared by every netbox group and only required if at least one group uses `DISCOVERY_SOURCE=netbox` — `preflight` fails if a netbox group exists but they're unset. Leave them blank for CIDR-only deployments.

## Multiple candidate credentials (unknown mapping)

If you have a long list of devices and several credentials but don't know which
credential goes with which device, you don't have to map them by hand. SNMP
discovery tries every candidate credential against every device, keeps whichever
authenticates, and records it **per device** in `state/devices-<group>.yaml`. The
poller then polls each device with its own credential — so a single group can end
up polling devices that use different communities or v3 users.

Give a group more than one candidate credential like this:

- **Multiple v2c communities** — make `SNMP_V2_COMMUNITY` a comma-separated list,
  e.g. `SNMP_V2_COMMUNITY="public,corp-ro,net-mon"`. Discovery tries each.
- **Multiple v3 credential sets** — keep the primary `SNMP_V3_*` set, then add
  numbered sets `SNMP_V3_USER_2` / `SNMP_V3_AUTH_PROTOCOL_2` / … through `_9`.
  Each numbered set must be complete (all five fields).
- **Both at once** — set `SNMP_VERSION=mixed` and provide any communities and/or
  v3 sets; discovery tries them all.

> Because group files are shell-sourced, **quote any value with spaces or shell
> characters** — that's why the comma list above is in quotes. Extra spaces
> inside the quotes are trimmed.

`groups/onboarding.env.sample` is a ready-made `mixed` group demonstrating this.
The typical workflow for a big unsorted pile:

```
cp groups/onboarding.env.sample groups/onboarding.env
# edit: candidate communities, v3 sets, and TARGETS = the range to onboard
make generate && make up && make discover GROUP=onboarding
```

Then review `state/devices-onboarding.yaml` — it lists each discovered device
with the credential that worked. Devices that answered nothing don't appear;
those are your follow-up list (wrong creds, ACLs blocking the poller host,
non-SNMP, or unreachable). Trying many communities across a wide range generates
a lot of probes — raise `DISCOVERY_THREADS` for speed, but mind device load,
IDS alerts, and TACACS account lockouts, and validate against a few IPs first.

## Render the configs

```
make generate
```

This produces (all git-ignored, derived artifacts — files the generator writes for you — **don't hand-edit them**; edit the templates in `templates/` instead):

- `config/discovery-<group>.yaml` — the canonical discovery config the discovery script feeds to ktranslate
- `config/poller-<group>.yaml` — the polling config, with the `devices:` block pointing at `state/devices-<group>.yaml` via an `@`-include (a reference that pulls in another file's contents)
- `config/catalog.yaml` — enrichment-only SNMP config for **flow** and **syslog** receivers; `@`-includes every group's `state/devices-<group>.yaml` so `device_name` and `user_tags` stay consistent across traffic types
- `compose-groups.generated.yaml` — service definitions for every group's poller and discovery container
- `compose-catalog.generated.yaml` — volume mounts for `ktranslate_flow` and `ktranslate_syslog` (catalog + all device files)

## Multi-group flow and syslog enrichment

SNMP pollers already read `state/devices-<group>.yaml` per credential group. **Flow** and **syslog** receivers share a generated **`config/catalog.yaml`** that lists every group's device file:

```yaml
devices:
  - "@/state/devices-cisco.yaml"
  - "@/state/devices-palo.yaml"
global:
  user_tags: {}
```

`make generate` also writes `compose-catalog.generated.yaml`, which mounts the catalog (as `/snmp.yaml`) plus every `state/devices-*.yaml` into `ktranslate_flow` and `ktranslate_syslog`. Both containers run with `--snmp=/snmp.yaml` (`--flow_only=true` on flow) so ktranslate can map exporter/source IPs to `device_name` and apply `global.user_tags` / per-device tags without polling.

When **any** group's device list changes, `scripts/run-discovery.sh` (or `make discover-all`) reloads **all** catalog consumers and SNMP pollers — flow/syslog restart; pollers receive `SIGUSR2`.

## Adding, removing, or modifying a group

Adding `groups/fortinet.env` is the whole change — no compose file edits, no script edits:

```
cp groups/cisco.env.sample groups/fortinet.env
# edit groups/fortinet.env: set GROUP=fortinet, fill creds, assign unique ports
make generate
make up
make discover GROUP=fortinet
```

`make up` is idempotent — it starts the new services without disturbing existing ones. Modifying or removing a group follows the same pattern (edit or delete the env file, re-run `make generate`, re-run `make up`).

## Flow DNS (`flow_dns`)

ktranslate enriches NetFlow rollups with `src_host` / `dst_host` via reverse DNS (`--dns=host:port`). The stock `--dns=127.0.0.1:53` default does nothing useful inside the container.

This stack runs a small **dnsmasq** sidecar (`flow_dns`) that:

1. **Answers PTR for discovered devices** — `scripts/refresh-flow-dns.sh` builds `host-record` lines from every `state/devices-*.yaml` (`device_name` + `device_ip`).
2. **Forwards everything else** to upstream DNS (`FLOW_DNS_UPSTREAM`, default `host.docker.internal` → your host resolver).

Optional knobs in `.env` (see `.env.sample`):

| Variable | Purpose |
|----------|---------|
| `FLOW_DNS` | ktranslate `--dns` target (default `flow_dns:53`) |
| `FLOW_DNS_UPSTREAM` | dnsmasq `server=` for recursion (default `host.docker.internal`) |
| `FLOW_DNS_EXTRA_HOSTS` | Comma-separated `name:ip` pairs not in SNMP discovery |
| `FLOW_DNS_DOCKER_NETWORK` / `FLOW_DNS_DOCKER_NODES` | Optional docker inspect overlay for dynamic lab mgmt IPs |

Operator-edited static records: copy `dnsmasq/extra-hosts.conf.sample` → `dnsmasq/extra-hosts.conf`.

`make flow-dns` regenerates records (also runs on `make up` and after discovery reload). Verify:

```
docker exec ktranslate_flow nslookup <device-ip> flow_dns
```

In production with corporate PTR records, point `--dns` at real DNS instead of `flow_dns`.

## Multiple environments on one host

Docker Compose reads `.env` from the current directory automatically. To maintain side-by-side environments (dev/staging/prod), keep additional files like `.env.prod` and select one at run time:

```
docker compose --env-file .env.prod -f compose-base.yaml -f compose-groups.generated.yaml up -d
```

## Running without the Makefile

The equivalent raw commands are:

```
./scripts/preflight.sh
./scripts/generate-groups.sh
echo '{}' | tee state/devices-cisco.yaml state/devices-palo.yaml   # bootstrap
./scripts/compute-limits.sh
docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml -f compose-limits.generated.yaml up -d
./scripts/run-discovery.sh cisco
# or discover every group in one shot:
make discover-all
```

The `discover_*` services are gated behind a Compose profile so `up` does not start them — they only run when invoked via `make discover` or `./scripts/run-discovery.sh`.
