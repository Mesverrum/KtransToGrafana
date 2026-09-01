# Architecture

[← back to README](../README.md)

In plain terms: a set of small containers run on one Linux host (via Docker Compose). Each one talks to your network in a way you already know (SNMP, netflow/sflow, syslog), converts what it collects into **metrics and logs**, and hands them to a shipping agent (Alloy) that forwards everything to Grafana Cloud. "OTEL"/"OTLP" below just mean the OpenTelemetry data format — the common shape ktranslate and Alloy use so they speak the same language.

The containers:

- **`ktranslate_flow`** — receives netflow data (netflow 5/9, sflow, ipfix, nbar, pan, etc.) and converts it into metrics. Mounts the generated **device catalog** (`config/catalog.yaml`) so flow records get the same `device_name` and tags as SNMP.
- **`ktranslate_snmp_<group>`** — one long-running SNMP poller per group (`ROLE=poll` or the default `both`). Each reads a settings file from `config/` plus a separately-managed device list from `state/`. The generated poller config sets `global.user_tags.snmp_group: <GROUP>` so every SNMP series from that poller carries credential-group metadata (exported as **`tags_snmp_group`** on OTLP series in Grafana Cloud).
- **`discover_<group>`** — one short-lived discovery container per group that discovers (`ROLE=discover` or `both`). Runs on a schedule, finds devices, writes the list back to `state/`, and tells pollers to reload (`SIGUSR2`). A `ROLE=discover` group can feed several pollers via [examples/vendor-split](../examples/vendor-split/README.md) (split on vendor, site, hostname, firmware, …) instead of polling the mixed list itself.
- **`ktranslate_syslog`** — collects syslog and forwards it as logs. Uses the same device catalog as flow for consistent naming/tags.
- **`ktranslate_traps`** — collated SNMP trap listener on **UDP/1620**. Same catalog as flow/syslog (`config/traps.yaml`). Pollers do not publish trap ports.
- **`alloy`** — a small Grafana Alloy agent that forwards everything from the containers above to Grafana Cloud.

```mermaid
flowchart TB
  subgraph net["Your network"]
    DEV["Routers · switches · firewalls"]
  end
  subgraph host["One Linux host — Docker Compose"]
    direction TB
    SNMP["ktranslate_snmp_&lt;group&gt;<br/>polls devices (one per group)"]
    DISC["discover_&lt;group&gt;<br/>finds devices, updates the list"]
    FLOW["ktranslate_flow<br/>receives netflow/sflow"]
    SYS["ktranslate_syslog<br/>receives syslog"]
    ALLOY["alloy<br/>forwards everything"]
  end
  GC[("Grafana Cloud")]
  DEV -->|SNMP| SNMP
  DEV -->|"netflow / sflow"| FLOW
  DEV -->|syslog| SYS
  DISC -.->|"writes device list"| SNMP
  SNMP --> ALLOY
  FLOW --> ALLOY
  SYS --> ALLOY
  ALLOY -->|"internet"| GC
```

The older hand-drawn diagrams below show the same flow in more detail:

![Architecture](../ktrans_architecture.png)
![Detail](../ktrans_to_alloy.png)

## The deployment model

A deployment is **N credential groups**, one declarative file each under `groups/<name>.env`. A generator script (`scripts/generate-groups.sh`) reads those files and renders the per-group config yamls plus a compose service fragment. Adding a credential group is a one-file operation followed by a re-run of the generator — no compose or script edits. One device is the same onboarding file with `TARGETS=<ip>/32`.

Each group picks its own **`DISCOVERY_SOURCE`** (`cidr` or `netbox`), so one deployment can mix a CIDR scan and a NetBox query side by side. See [configuration.md](configuration.md) for the group reference.

## Sizing (rule of thumb)

These are **field planning numbers**, not SLAs. They assume a current `kentik/ktranslate` image, default-ish poll intervals, and “average” campus/access switches — not a chassis with tens of thousands of interfaces, not 15-second polls, and not devices that sit at SNMP timeout. Size for **peak** CPU in a poll cycle (ktranslate spikes at the start of each walk); an average of 60% can hide a container that is already hitting 100%.

Budget **each ktranslate process** on its own. In this repo SNMP, flow, and syslog are already separate containers — do not spend the same 1 CPU on 500 polled devices *and* 1000 events/s.

| Workload | Starting budget | What “1 unit” covers |
| --- | --- | --- |
| SNMP polling | **1 CPU + 1 GiB RAM** | about **500** average switches / similar network devices |
| NetFlow / sFlow / IPFIX, traps, or syslog | **1 CPU + 1 GiB RAM** | about **1000 events per second** of that signal |

Worked examples:

- 1 200 access switches, SNMP only → about **3 CPU / 3 GiB** on the poller (or two groups if you want a smaller blast radius).
- 4 000 flow records/s → about **4 CPU / 4 GiB** on `ktranslate_flow`.
- Traps *and* syslog are each their own 1000 events/s column if they share a host.

What eats the SNMP budget faster than “500 devices”:

- Large interface tables (core / DC / wireless controllers)
- Short `poll_time_sec`, high `timeout_ms` / `retries`
- Extra MIBs in `mibs_enabled` (BGP, entity sensors, vendor tables — discovery unions these in automatically; pin with `MIBS_ENABLED=` if you need a shorter list)
- Devices that never answer (walks sit on timeout)

The upstream [ktranslate CPU notes](https://github.com/kentik/ktranslate/wiki/Understanding-KTranslate-CPU-Usage) quote a bit more headroom on flow/syslog (~2000 events/s per core, traps ~1000/s) and do not call out RAM. The table above is the **conservative** plan: 1000 events/s per CPU **and** 1 GiB, so you have room for OTLP export and a noisy day.

Leave **Alloy + the host OS** outside this math. Compose memory caps (`MEM_SNMP_MAX`, etc.) are documented in [operations.md](operations.md#memory-limits). On Kubernetes, raise `resources` on that one poller or add groups — do not `replicas: 2` the same listener ([k8s/LIMITATIONS.md](../k8s/LIMITATIONS.md#3-scale-up-vs-scale-wide)).

## Why discovery and polling are split

The split between discovery and polling lets **git stay the source of truth** for credentials, scan ranges, and polling rules, while letting **the network itself be the source of truth** for which devices currently exist **and which MIBs they expose**. Discovery writes the device list (and each device's `discovered_mibs`) atomically; the generator copies that MIB union into the poller's `global.mibs_enabled` so vendor tables (CPU, BGP, Infoblox, NetApp, …) are polled without a hand-edit. ktranslate itself never mutates the poller YAML (it is generated, then mounted read-only). Override the union with `MIBS_ENABLED=` or `ADD_DISCOVERED_MIBS=0` on the group file — see [configuration.md](configuration.md#mibs_enabled).

## Compose interpolation vs. per-service `env_file:`

There are two distinct mechanisms in Docker Compose for "loading variables from a file," and the distinction matters if you extend this setup:

- **Compose-level interpolation (what this repo uses)** — variables in `.env` are substituted into the compose file *at parse time*, before any container is created. They become whatever you reference them as (`environment:`, `command:`, ports, image tags, etc.). The container itself never sees `.env`; it only sees what you explicitly hand it via the `environment:` block.
- **Per-service `env_file:`** — adding `env_file: [.env]` to a service block injects the file's contents *into that container's environment* at runtime. Use this when a container expects to read a variable it wasn't explicitly given via `environment:` — for example, a third-party image that auto-reads `MY_API_KEY` from `os.environ`. None of the containers in this repo need that, so we rely on interpolation alone.

The `config.alloy.sample` file is already wired to the `GC_OTLP_*` env vars — do not copy or edit it for Grafana Cloud. `make up` runs `compose-base.yaml.sample` (`bash scripts/compose-files.sh`). To change Alloy or Compose, see [Customizing Alloy and Compose](#customizing-alloy-and-compose). If Grafana Explore is empty, walk the hops in [troubleshooting/bring-up.md](../troubleshooting/bring-up.md): discovery YAML → Alloy metrics on host `:12346` → PromQL `kentik_snmp_CPU` (not `kentik_snmp_DeviceMetrics`).

## Customizing Alloy and Compose

Do **not** copy `compose-base.yaml.sample` or `config.alloy.sample`, and do **not** edit those tracked files in place — `git pull` owns them. Site-specific changes go in gitignored files so they survive pulls without blocking sample updates.

`make up` / `make discover` / `make split-devices` already layer `compose.override.yaml` when that file exists (`scripts/compose-files.sh`). Docker Compose merges it on top of the sample.

### Extra port, extra network, extra volume

Create `compose.override.yaml` in the repo root (already gitignored):

```yaml
services:
  ktranslate_flow:
    ports:
      - "9997:9997/udp"          # additional listener; 9995 from the sample stays
  alloy:
    networks:
      - labnet

networks:
  labnet:
    external: true
```

Then `make up` again. You only list the keys you are adding or replacing.

### Fork Alloy (OSS exporter, extra processors)

1. `cp config.alloy.sample config.alloy` (gitignored).
2. Edit `config.alloy` — for Grafana OSS, keep the pipeline through `otelcol.processor.batch` and replace `otelcol.exporter.otlphttp "grafana_cloud"` / `otelcol.auth.basic "grafana_cloud"` with your Prometheus (and Loki) exporters.
3. Point Compose at the fork with `compose.override.yaml`:

```yaml
services:
  alloy:
    volumes:
      - type: bind
        source: ./config.alloy
        target: /config.alloy
```

4. `make up`. Kubernetes: `make generate-k8s` embeds `config.alloy` when that file exists, otherwise `config.alloy.sample`.

You now own freshness of `config.alloy`. After a `git pull` that changes `config.alloy.sample`, diff them and merge what you still want.

### Join an Alloy you already run

The bundled `alloy` service is what ktranslate talks to (`--otel.endpoint=http://alloy:4317/`). To send to another Alloy instead:

1. In `compose.override.yaml`, attach `ktranslate_flow`, `ktranslate_syslog`, `ktranslate_traps`, and each `ktranslate_snmp_*` to that Alloy's Docker network.
2. Replace each service's `command:` `--otel.endpoint=…` with the other Alloy's address. `command:` in an override **replaces** the whole list — copy it from `compose-base.yaml.sample` (flow / syslog / traps) or `compose-groups.generated.yaml` (pollers) and change only the endpoint.
3. Optionally stop the bundled Alloy by giving it a profile the default `up` does not enable:

```yaml
services:
  alloy:
    profiles:
      - bundled-alloy
```

### What not to do

| Don't | Do |
|---|---|
| `cp compose-base.yaml.sample compose-base.yaml` | `compose.override.yaml` (the copy is unused) |
| Edit `config.alloy.sample` / `compose-base.yaml.sample` | Fork `config.alloy` + override volume, or override Compose keys |
| Expect a leftover `config.alloy` to be mounted automatically on Compose | Mount it explicitly in `compose.override.yaml` |

## Kubernetes is another runtime, not another model

`make k8s-up` applies the same generated poller/discovery/catalog YAML as Deployments, a PVC for `state/devices-*.yaml`, and a CronJob instead of host cron. Alloy still forwards to Grafana Cloud. Groups, `KTRANS_HOST`, and the dashboards do not change.

Kubernetes does **not** change the hard parts of talking to network gear (stable destination IPs, one poller per device list, UDP loss on restart). Those are called out in [k8s/LIMITATIONS.md](../k8s/LIMITATIONS.md). Operator steps: [kubernetes.md](kubernetes.md).
