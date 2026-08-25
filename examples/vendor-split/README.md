# One discovery scan, many vendor pollers

Subnets are rarely clean by vendor. This example keeps **discovery as its own
layer** (one mixed-CIDR scan) and **polling as failure domains** (one long-running
ktranslate per vendor). New devices land in the right poller without restarting
it — ktranslate reloads the `@`-included device list on **SIGUSR2**.

```
  CIDRs (mixed vendors)
           │
           ▼
   discover_estate          ROLE=discover  (short-lived)
           │
           ▼
  state/devices-estate.yaml
           │
           ▼
  split-devices-by-vendor.py     mib_profile / sysObjectID
           │
     ┌─────┼──────┬─────────┐
     ▼     ▼      ▼         ▼
  cisco  palo  juniper    other     ROLE=poll  (SIGUSR2 on change)
```

Flow and syslog still mount a **catalog** of every poller file, so a syslog
source IP maps back to the SNMP `device_name` regardless of which poller owns
the box.

Needs **Python 3** and **PyYAML** (`sudo apt install python3-yaml`) in addition to the usual `yq` / `envsubst` host tools.

## Bring-up

Do not also copy `groups/onboarding.env.sample` or `groups/single.env.sample`.
`make generate` starts every `groups/*.env`.

```
# from the repo root
cp examples/vendor-split/groups/estate.env.sample  groups/estate.env
cp examples/vendor-split/groups/cisco.env.sample   groups/cisco.env
cp examples/vendor-split/groups/palo.env.sample    groups/palo.env
cp examples/vendor-split/groups/juniper.env.sample groups/juniper.env
cp examples/vendor-split/groups/other.env.sample   groups/other.env
cp examples/vendor-split/vendor-split.yaml         config/vendor-split.yaml

# edit groups/estate.env: TARGETS + candidate credentials
make generate
sudo chown -R 1000:1000 config state
make up
make discover GROUP=estate
```

`make discover GROUP=estate` scans, publishes `state/devices-estate.yaml`,
splits into `state/devices-{cisco,palo,juniper,other}.yaml`, then SIGUSR2s the
vendor pollers (and restarts flow/syslog so the catalog re-reads).

Re-run the split after you edit the mapping (estate list unchanged):

```
make split-vendors
```

Dry-run / fixture check:

```
python3 scripts/split-devices-by-vendor.py --self-test
python3 scripts/split-devices-by-vendor.py --dry-run
```

## How devices are classified

[vendor-split.yaml](vendor-split.yaml) is first-match-wins on:

1. `mib_profile` glob (`cisco*`, `palo*`, …) — ktranslate writes this from
   [kentik/snmp-profiles](https://github.com/kentik/snmp-profiles) during discovery
2. `oid_prefix` (sysObjectID enterprise, e.g. `.1.3.6.1.4.1.9` = Cisco)
3. optional `provider` glob

Anything unmatched goes to `default_group` (`other`) so a UPS or an unknown
profile is not dropped.

Add a vendor: copy a `ROLE=poll` sample, give it unique `GROUP` + ports, add a
rule in `vendor-split.yaml`, `make generate && make split-vendors`.

## What is *not* in this example

- Sorting by **role** (router vs access) instead of vendor — same script, different
  rules (match `provider: kentik-router` or a `user_tags` you stamp).
- Kubernetes CronJob running the splitter inside the cluster. Compose is the
  worked example; `make generate-k8s` still emits a discover Deployment for
  `ROLE=discover` and poller Deployments for `ROLE=poll`. Run the splitter on
  a host that can write the PVC, or `make split-vendors` against a synced
  `state/` copy, until a split Job is added.

## Reload signal

Use **SIGUSR2**, not SIGHUP. SIGHUP has no handler and stops the container.
See [scripts/reload-ktranslate-devices.sh](../../scripts/reload-ktranslate-devices.sh)
and [docs/operations.md](../../docs/operations.md#scheduled-discovery).
