# One discovery scan, many pollers

The **default path** is onboarding, then an optional dynamic split — you do not
copy these sample groups first:

```
make discover GROUP=onboarding
make split-devices          # vendor family from mib_profile; provisions pollers
```

Traps, syslog, and flow stay on the catalog listener (`UDP/1620` for traps).
This directory is the **override** path: static YAML matchers (site CIDR,
hostname, firmware). Poller `groups/*.env` files are provisioned by
`make split-devices` — do not copy named vendor samples.

---

Subnets are rarely clean by vendor, site, or role. This example keeps
**discovery as its own layer** (one mixed-CIDR scan) and **polling as
failure domains** (one long-running ktranslate per bucket). You chop the
discovered device list on **any field it already holds** — vendor, profile,
hostname, IP subnet, firmware in sysDescr, nested tags — by editing YAML,
not by writing a new script.

New devices land in the right poller without restarting it. ktranslate
reloads the `@`-included device list on **SIGUSR2**.

```
  CIDRs (mixed vendors / sites)
           │
           ▼
   discover_estate          ROLE=discover  (short-lived)
           │
           ▼
  state/devices-estate.yaml
           │
           ▼
  split-devices.py          config/device-split.yaml
           │
     ┌─────┼──────┬─────────┐
     ▼     ▼      ▼         ▼
  cisco  palo  juniper    other     ROLE=poll  (SIGUSR2 on change)
  (or hq / branch / site-dc1 / … — whatever GROUP= you defined)
```

Flow and syslog still mount a **catalog** of every poller file, so a syslog
source IP maps back to the SNMP `device_name` regardless of which poller owns
the box.

Needs **Python 3** and **PyYAML** (`sudo apt install python3-yaml`) in addition
to the usual `yq` / `envsubst` host tools.

## Bring-up (static mapping override)

Prefer onboarding + `make split-devices` (dynamic vendors). Use this only when
you want a `ROLE=discover` estate group and a committed `config/device-split.yaml`.
Do not also copy `groups/onboarding.env`.

```
# from the repo root
cp examples/vendor-split/groups/estate.env.sample  groups/estate.env
cp examples/vendor-split/device-split.yaml         config/device-split.yaml

# edit groups/estate.env: TARGETS + candidate credentials
make generate
sudo chown -R 1000:1000 config state
make up
make discover GROUP=estate
```

`make discover GROUP=estate` scans, publishes `state/devices-estate.yaml`,
splits into poller files (provisioning `groups/<vendor>.env` as needed), then
SIGUSR2s the pollers (and restarts flow/syslog/traps so the catalog re-reads).

Re-run the split after you edit the mapping (estate list unchanged):

```
make split-devices
```

(`make split-vendors` is the same target.)

## Inspect first, then edit YAML

You do not need a custom script to learn what you can split on. After a scan
(or against the bundled fixture):

```
python3 scripts/split-devices.py --list-fields
python3 scripts/split-devices.py --list-values mib_profile
python3 scripts/split-devices.py --list-values description
python3 scripts/split-devices.py --list-values device_ip
python3 scripts/split-devices.py --dry-run --explain
python3 scripts/split-devices.py --dry-run --explain --ignore-pollers
python3 scripts/split-devices.py --self-test
```

`--list-fields` prints every key on the device list plus sample values.
`--explain` shows which rule caught each device. If a rule's destination has
no `ROLE=poll` group yet, that is listed as `skipped … (no poller)` and the
device falls through — `--ignore-pollers` previews buckets before you create
those group files. Tweak `config/device-split.yaml` and re-run
`make split-devices`.

Mapping lookup (first file that exists): `config/device-split.yaml`,
`config/vendor-split.yaml`, then the copies under `examples/vendor-split/`.

## How matching works

First matching rule wins. If that rule's destination is **not** a
`ROLE=poll` group in `groups/*.env`, the device falls through to the next
rule, then `default_group` (`other` here) so nothing is dropped.

Each destination name must match a poller's `GROUP=`. Adding a bucket:
`make split-devices` provisions missing `groups/<name>.env` as `ROLE=poll`,
or copy `groups/onboarding.env.sample`, set `GROUP=` / `ROLE=poll` / unique
ports, add a rule whose `group:` matches that name, then `make generate &&
make split-devices`.

### Operators (any field)

Put these on a clause with `field:` (aliases: `hostname`/`name` → `device_name`,
`ip`/`address` → `device_ip`, `profile` → `mib_profile`, `sysdescr`/`firmware`
→ `description`, `sysoid` → `oid`). Nested maps use dots (`user_tags.site`).

| Operator | Matches |
|----------|---------|
| `equals` / `eq` / `in` | exact value (case-insensitive unless `case: sensitive`) |
| `glob` | shell glob (`cisco*`) |
| `contains` / `substring` | substring |
| `prefix` | string prefix; on `oid` this is a sysObjectID prefix |
| `regex` | regex; captures fill `group: "site-{1}"` |
| `cidr` | IPv4/IPv6 membership (`10.10.0.0/16`) |
| `exists` | field present / non-empty (`exists: true`) |
| `not:` / `negate:` | invert that clause |

Combine clauses with `any:` / `or:` (OR) or `match:` / `all:` (AND).

Shorthand still works and ORs together (this is what [device-split.yaml](device-split.yaml)
uses for the vendor bring-up): `mib_profile`, `oid_prefix`, `provider`.

Destinations:

- `group: cisco` — static poller name
- `group: "site-{1}"` — regex capture
- `group_from: mib_profile` plus `group_transform: stem` (also `slug`, `lower`)

### Copy-paste recipes

Swap `config/device-split.yaml` for one of these, or merge rules.
`make split-devices` provisions missing `ROLE=poll` groups (unmatched
devices land in `other` until that poller exists).

| File | Boundary |
|------|----------|
| [recipes/by-dynamic-vendor.yaml](recipes/by-dynamic-vendor.yaml) | **default** — vendor family from `mib_profile` |
| [device-split.yaml](device-split.yaml) / [vendor-split.yaml](vendor-split.yaml) | static vendor globs + sysObjectID |
| [recipes/by-site-cidr.yaml](recipes/by-site-cidr.yaml) | management IP subnet |
| [recipes/by-hostname.yaml](recipes/by-hostname.yaml) | hostname regex → `site-{1}` |
| [recipes/by-firmware.yaml](recipes/by-firmware.yaml) | OS / version in `description` |
| [recipes/by-vendor-and-site.yaml](recipes/by-vendor-and-site.yaml) | profile **and** subnet |
| [recipes/by-profile.yaml](recipes/by-profile.yaml) | one group per profile stem |

Try any recipe against the fixture (no live lab required):

```
python3 scripts/split-devices.py \
  --mapping examples/vendor-split/recipes/by-site-cidr.yaml \
  --from examples/vendor-split/testdata/devices-estate.yaml \
  --dry-run --explain --ignore-pollers
```

## Worked examples (same six devices)

[testdata/devices-estate.yaml](testdata/devices-estate.yaml) is a fake discovery
result. Every recipe below is first-match-wins against that file.

| key | hostname | IP | profile | sysDescr (excerpt) |
|-----|----------|----|---------|--------------------|
| `core1` | `dc1-core1` | `10.0.0.1` | `cisco-nexus.yml` | NX-OS 9.3 |
| `fw1` | `fw1` | `10.0.0.2` | `paloalto.yml` | PA-3220 10.2.3 |
| `ex1` | `dc2-ex1` | `10.2.0.4` | `juniper-ex.yml` | Juniper ex4300 |
| `ups1` | `ups1` | `10.0.0.3` | `apc_ups.yml` | APC Smart-UPS |
| `hq-leaf` | `hq-leaf-01` | `10.10.1.5` | `cisco-catalyst.yml` | IOS C9300; `user_tags.site: hq` |
| `br-leaf` | `br1-leaf-01` | `10.20.1.5` | `cisco-iosxe.yml` | IOS-XE 17.9.4 |

### 1. Split by vendor (dynamic — default)

No mapping file. `mib_profile` → vendor family (`cisco-nexus.yml` and
`cisco-iosxe.yml` both become `cisco`). `make split-devices` provisions the
poller env files.

[recipes/by-dynamic-vendor.yaml](recipes/by-dynamic-vendor.yaml) pins that
behaviour if you want it in git. The static glob file below is only if you
need OID prefixes or different bucket names.

[device-split.yaml](device-split.yaml) ORs a profile glob with a sysObjectID
prefix. `cisco-nexus.yml` matches `cisco*`; Palo's OID is `.1.3.6.1.4.1.25461`;
the UPS matches neither and lands in `other`.

```yaml
- group: cisco
  mib_profile: ["cisco*", "catalyst*", "nexus*", "meraki*"]
  oid_prefix: [".1.3.6.1.4.1.9"]
```

| Poller | Devices |
|--------|---------|
| `cisco` | core1, hq-leaf, br-leaf |
| `palo` | fw1 |
| `juniper` | ex1 |
| `other` | ups1 |

That is the layout `make discover GROUP=estate` produces: the splitter
provisions `groups/<vendor>.env` as `ROLE=poll`. Each poller is its own
failure domain — a stuck Cisco walk does not take down the Palo or Juniper
containers.

### 2. Split by site (management subnet)

Locations often show up as IP plan, not as a clean vendor CIDR.
[recipes/by-site-cidr.yaml](recipes/by-site-cidr.yaml):

```yaml
- group: hq
  match:
    - field: device_ip
      cidr: [10.10.0.0/16, 10.11.0.0/16]
- group: branch
  match:
    - field: device_ip
      cidr: 10.20.0.0/12
```

| Poller | Devices | Why |
|--------|---------|-----|
| `hq` | hq-leaf | `10.10.1.5` |
| `branch` | br-leaf | `10.20.1.5` |
| `other` | core1, fw1, ex1, ups1 | `10.0.0.0/24` and `10.2.0.4` are not those sites |

Point `config/device-split.yaml` at this recipe and run `make split-devices`
(it provisions `groups/hq.env` / `groups/branch.env` as `ROLE=poll`). Or copy
`groups/onboarding.env.sample`, set `GROUP=` / `ROLE=poll` and unique ports.

### 3. Split by hostname (site prefix)

Same idea when the naming standard is `dc1-core1`, `dc2-ex1`.
[recipes/by-hostname.yaml](recipes/by-hostname.yaml) captures the prefix:

```yaml
- group: "site-{1}"
  match:
    - field: device_name
      regex: '^(dc\d+)-'
```

| Poller | Devices |
|--------|---------|
| `site-dc1` | core1 (`dc1-core1`) |
| `site-dc2` | ex1 (`dc2-ex1`) |
| `other` | fw1, ups1, hq-leaf, br-leaf (names do not start with `dcN-`) |

`{1}` is regex capture group 1. You still create `groups/site-dc1.env` (and
`site-dc2`) as `ROLE=poll` — or preview first with `--ignore-pollers` so you
can see the names before adding those files. Tighten the regex with
`--list-values device_name` on a real estate list.

### 4. Split by firmware / OS in sysDescr

ktranslate stores sysDescr as `description`.
[recipes/by-firmware.yaml](recipes/by-firmware.yaml):

```yaml
- group: iosxe17
  match:
    - field: description
      regex: 'IOS-XE.*17\.9'
- group: nxos9
  match:
    - field: description
      contains: NX-OS
```

| Poller | Devices |
|--------|---------|
| `iosxe17` | br-leaf (`…Version 17.9.4`) |
| `nxos9` | core1 (`Cisco NX-OS(tm) 9.3(10)`) |
| `other` | everyone else |

Use `--list-values description` on live discovery output, then adjust the
regex. `field: firmware` is an alias for `description`.

### 5. Two dimensions at once (vendor AND site)

[recipes/by-vendor-and-site.yaml](recipes/by-vendor-and-site.yaml) — HQ Cisco
on its own poller, remaining Cisco on the generic Cisco poller:

```yaml
- group: hq-cisco
  match:
    - field: mib_profile
      glob: "cisco*"
    - field: device_ip
      cidr: 10.10.0.0/16
- group: cisco
  mib_profile: ["cisco*"]
  oid_prefix: [".1.3.6.1.4.1.9"]
```

`match:` is AND. First rule wins, so hq-leaf is not also counted as `cisco`.

| Poller | Devices |
|--------|---------|
| `hq-cisco` | hq-leaf (Cisco profile **and** `10.10.0.0/16`) |
| `cisco` | core1, br-leaf |
| `other` | fw1, ex1, ups1 |

OR is `any:` (profile glob **or** OID prefix is what the vendor shorthand
does). Nested tags work the same way: `field: user_tags.site` / `equals: hq`
would send only hq-leaf to a `tagged-hq` poller.

### 6. One poller per SNMP profile (no hand-written names)

[recipes/by-profile.yaml](recipes/by-profile.yaml) derives the group from the
field:

```yaml
- group_from: mib_profile
  group_transform: stem    # cisco-nexus.yml → cisco-nexus
```

| Poller | Device |
|--------|--------|
| `cisco-nexus` | core1 |
| `paloalto` | fw1 |
| `juniper-ex` | ex1 |
| `apc_ups` | ups1 |
| `cisco-catalyst` | hq-leaf |
| `cisco-iosxe` | br-leaf |

Useful when you want a container per kentik profile. You still need a
`groups/<stem>.env` for each destination you want to keep; anything without a
poller falls through to `other`.

## What is *not* in this example

- Kubernetes CronJob running the splitter inside the cluster. Compose is the
  worked example; `make generate-k8s` still emits a discover Deployment for
  `ROLE=discover` and poller Deployments for `ROLE=poll`. Run the splitter on
  a host that can write the PVC, or `make split-devices` against a synced
  `state/` copy, until a split Job is added.

## Reload signal

Use **SIGUSR2**, not SIGHUP. SIGHUP has no handler and stops the container.
See [scripts/reload-ktranslate-devices.sh](../../scripts/reload-ktranslate-devices.sh)
and [docs/operations.md](../../docs/operations.md#scheduled-discovery).
