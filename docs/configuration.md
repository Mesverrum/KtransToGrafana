# Configuring credential groups

[← back to README](../README.md)

Each file in `groups/*.env` is one credential group. The [quickstart](../README.md#quickstart--onboard-your-devices-in-about-15-minutes) walks through onboarding a range with candidate credentials; this doc covers multiple groups, both discovery sources, and the credential options in depth.

**Copy only the samples you will run.** `make generate` and `make up` start **every** `groups/*.env` — `GROUP=` is not a filter there (it only applies to `make discover`). Copying both `onboarding.env` and `single.env` (or every vendor sample) starts two or more SNMP pollers and leftover containers. Get one group into Grafana first, then add more.

Sample files (copy whichever fit — not all of them):

```
cp groups/onboarding.env.sample groups/onboarding.env  # mixed creds + CIDR range
cp groups/single.env.sample     groups/single.env      # one IP, one credential
cp groups/cisco.env.sample      groups/cisco.env       # CIDR discovery, SNMP v3 example
cp groups/palo.env.sample       groups/palo.env        # NetBox discovery, SNMP v2c example
```

Copy additional sample files to define more groups (e.g. `cp groups/cisco.env.sample groups/fortinet.env`). The generator picks up everything matching `groups/*.env`.

## Common fields

Every variable is documented inline in the sample. The important ones:

- **`GROUP`** — short identifier (`cisco`, `palo`, etc.). Used in container names, file paths, the OTEL `service.name` (a label identifying which collector produced the data), and stamped on every SNMP metric via `global.user_tags.snmp_group` in the generated poller config. In Grafana Explore the label appears as **`tags_snmp_group`** (OTLP export); dashboard variable **`$snmp_group`** filters with `tags_snmp_group=~"$snmp_group"`. Prefer that over `service_name` when filtering fleet dashboards by credential group — `service_name` also varies with `KTRANS_HOST` when you run multiple deployments.
- **`SNMP_VERSION`** — `v2c`, `v3`, or `mixed`. The other credential fields are only required for the matching version; `mixed` lets one group carry both v2c and v3 candidates (see [Multiple candidate credentials](#multiple-candidate-credentials-unknown-mapping)).
- **`DISCOVERY_SOURCE`** — where this group's device list comes from: `cidr`, `netbox`, or `split` (defaults to `cidr` if unset, or `split` when `ROLE=poll`).
- **`ROLE`** — `both` (default: discover + poll), `discover` (scan only), or `poll` (poller only; inventory comes from another group's scan). See [One discovery scan, many pollers](#one-discovery-scan-many-pollers).
- **`METALISTEN_PORT` / `TRAP_PORT`** — `METALISTEN_PORT` is the poller's debug port and must be unique. **Traps are collated**: devices send SNMP traps to the host **UDP/1620** (`ktranslate_traps` + the device catalog), same idea as syslog `:1514` and flow `:9995`. Per-poller `TRAP_PORT` is only inside the container YAML (not published). Must not collide with static TCP ports (9994, 9995, 9996, 9998, 4317, 12346).

### `snmp_group` on metrics

Each poller's generated `config/poller-<group>.yaml` sets:

```yaml
global:
  user_tags:
    snmp_group: <GROUP>
```

ktranslate copies `global.user_tags` onto every SNMP series from that poller. When metrics are exported via **OTLP** to Grafana Cloud (the default in this stack), the label appears as **`tags_snmp_group`** on series — the dashboard variable is still named `$snmp_group`, but PromQL filters use `tags_snmp_group=~"$snmp_group"`. After discovery, verify in Grafana Explore:

```
count by (tags_snmp_group, device_name) (kentik_snmp_CPU)
```

(`kentik_snmp_PollingHealth` is equivalent. Do not query `kentik_snmp_DeviceMetrics` — that series is not on this OTLP path.)

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

## One discovery scan, many pollers

Start with **onboarding** (`ROLE=both`): one scan, mixed credentials, one poller. When you want failure domains, split that list — you do **not** pre-create `cisco.env` / `palo.env`.

```
make discover GROUP=onboarding
make split-devices
```

`make split-devices` (default, no mapping file):

1. Reads `state/devices-onboarding.yaml` (or `estate`).
2. **Dynamically** buckets devices by vendor family derived from `mib_profile` (`cisco-nexus.yml` → `cisco`, `paloalto.yml` → `palo`, unknown stems → first token).
3. **Provisions** missing `groups/<vendor>.env` as `ROLE=poll` (unique `METALISTEN_PORT`).
4. Sets the source group to **`ROLE=discover`** so the mixed list is not polled twice.
5. Regenerates compose, `up -d --remove-orphans`, SIGUSR2s pollers.

Traps, syslog, and flow stay on **one catalog listener** (`ktranslate_traps` UDP/1620, syslog 1514, flow 9995). They `@`-include every poller device file so enrichment does not depend on which poller walks the box.

Later discovers on a `ROLE=discover` group re-run the split, so a new vendor in the estate gets a new poller without a new matcher.

Override the default with `config/device-split.yaml` (static rules, CIDR, hostname, firmware — [examples/vendor-split](../examples/vendor-split/README.md)). Preview:

```
python3 scripts/split-devices.py --dynamic vendor --dry-run --explain \
  --from examples/vendor-split/testdata/devices-estate.yaml
```

Needs PyYAML (`sudo apt install python3-yaml`).

The catalog `@`-includes poller files only (not the raw scan list), so flow/syslog/traps map source IPs to `device_name` without double-counting.

### Examples of split rules

You do not write a new script for each boundary. Copy a recipe, or paste a
rule into `config/device-split.yaml`. Against the six-device fixture in
[examples/vendor-split/testdata/devices-estate.yaml](../examples/vendor-split/testdata/devices-estate.yaml)
those recipes land as follows (full walkthrough:
[examples/vendor-split/README.md](../examples/vendor-split/README.md#worked-examples-same-six-devices)).

**Vendor** (default, no YAML) — `core1` / `hq-leaf` / `br-leaf` → `cisco`, `fw1` → `palo`, `ex1` → `juniper`, `ups1` → `apc` (first token of `apc_ups.yml`). Static glob files send unknown profiles to `other` instead.

**Site from IP plan:**

```yaml
- group: hq
  match:
    - field: device_ip
      cidr: 10.10.0.0/16
```

`hq-leaf` (`10.10.1.5`) → poller `hq`. Hosts in other subnets fall through.

**Site from hostname** (`dc1-core1` → poller `site-dc1`):

```yaml
- group: "site-{1}"
  match:
    - field: device_name
      regex: '^(dc\d+)-'
```

**Firmware in sysDescr** (stored as `description`):

```yaml
- group: iosxe17
  match:
    - field: description
      regex: 'IOS-XE.*17\.9'
```

**Vendor AND site** (AND is `match:`; OR is `any:`):

```yaml
- group: hq-cisco
  match:
    - field: mib_profile
      glob: "cisco*"
    - field: device_ip
      cidr: 10.10.0.0/16
```

Preview without creating poller files yet:

```
python3 scripts/split-devices.py --dry-run --explain --ignore-pollers \
  --mapping examples/vendor-split/recipes/by-hostname.yaml \
  --from examples/vendor-split/testdata/devices-estate.yaml
```

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

## SNMPv3 via AWS Secrets Manager (optional)

To keep passphrases out of `groups/*.env` and generated YAML, set **`SNMP_V3_SECRET=aws.sm.<secret-name>`** on a `SNMP_VERSION=v3` group instead of the inline `SNMP_V3_USER` / `*_PASS` fields. Sample: `groups/secure-aws.env.sample`. Full steps (secret JSON shape, IAM, `.env` `AWS_REGION`): **[secrets-aws.md](secrets-aws.md)**.

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

Docker Compose reads `.env` from the current directory automatically. To maintain side-by-side environments (dev/staging/prod), keep additional files like `.env.prod` and select one at run time. Export `KTRANS_HOST` first if that file leaves it blank:

```
export KTRANS_HOST=$(bash scripts/host-id.sh)
docker compose --env-file .env.prod -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml up -d
```

## Running without the Makefile

Prefer `make up` — it fills `KTRANS_HOST` from hostname when `.env` leaves it blank. Raw Compose interpolates a blank `KTRANS_HOST` as `deployment.host=` and Alloy can crash.

```
export KTRANS_HOST=$(bash scripts/host-id.sh)   # required if KTRANS_HOST= is blank in .env
bash scripts/preflight.sh
bash scripts/generate-groups.sh                 # renders ALL groups/*.env (no GROUP= filter)
echo '{}' | tee state/devices-cisco.yaml state/devices-palo.yaml   # bootstrap
bash scripts/compute-limits.sh
docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml -f compose-limits.generated.yaml up -d
bash scripts/run-discovery.sh cisco
# or discover every group in one shot:
make discover-all
```

Git on Windows / some zip extracts drop execute bits. Always invoke `bash scripts/…` (not `./scripts/foo.sh`) unless you have run `chmod a+x scripts/*.sh`.

The `discover_*` services are gated behind a Compose profile so `up` does not start them — they only run when invoked via `make discover` or `bash scripts/run-discovery.sh`.
