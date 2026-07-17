# Configuring credential groups

[← back to README](../README.md)

Each file in `groups/*.env` is one credential group. The [quickstart](../README.md#quickstart--one-device-in-about-10-minutes) covers the single-device case; this doc covers multiple groups and both discovery sources.

Three sample groups ship in the repo — copy whichever fit your environment:

```
cp groups/single.env.sample groups/single.env   # minimal single-device CIDR group
cp groups/cisco.env.sample  groups/cisco.env     # CIDR discovery, SNMP v3 example
cp groups/palo.env.sample   groups/palo.env      # NetBox discovery, SNMP v2c example
```

Copy only the ones you need, and copy additional sample files to define more groups (e.g. `cp groups/cisco.env.sample groups/fortinet.env`). The generator picks up everything matching `groups/*.env`.

## Common fields

Every variable is documented inline in the sample. The important ones:

- **`GROUP`** — short identifier (`cisco`, `palo`, etc.). Used in container names, file paths, and the OTEL `service.name` (a label identifying which collector produced the data) so dashboards can split by group.
- **`SNMP_VERSION`** — `v2c` or `v3`. The other credential fields are only required for the matching version.
- **`DISCOVERY_SOURCE`** — where this group's device list comes from: `cidr` or `netbox` (defaults to `cidr` if unset).
- **`METALISTEN_PORT` / `TRAP_PORT`** — host ports for this group. Must be unique across groups and must not collide with the static services (9995, 9996, 9998, 4317, 12346, 1514). The generator refuses to run if it finds a collision.

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

## Render the configs

```
make generate
```

This produces (all git-ignored, derived artifacts — files the generator writes for you — **don't hand-edit them**; edit the templates in `templates/` instead):

- `config/discovery-<group>.yaml` — the canonical discovery config the discovery script feeds to ktranslate
- `config/poller-<group>.yaml` — the polling config, with the `devices:` block pointing at `state/devices-<group>.yaml` via an `@`-include (a reference that pulls in another file's contents)
- `compose-groups.generated.yaml` — service definitions for every group's poller and discovery container

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
docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-limits.generated.yaml up -d
./scripts/run-discovery.sh cisco
```

The `discover_*` services are gated behind a Compose profile so `up` does not start them — they only run when invoked via `make discover` or `./scripts/run-discovery.sh`.
