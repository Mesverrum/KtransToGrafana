# Architecture

[← back to README](../README.md)

In plain terms: a set of small containers run on one Linux host (via Docker Compose). Each one talks to your network in a way you already know (SNMP, netflow/sflow, syslog), converts what it collects into **metrics and logs**, and hands them to a shipping agent (Alloy) that forwards everything to Grafana Cloud. "OTEL"/"OTLP" below just mean the OpenTelemetry data format — the common shape ktranslate and Alloy use so they speak the same language.

The containers:

- **`ktranslate_flow`** — receives netflow data (netflow 5/9, sflow, ipfix, nbar, pan, etc.) and converts it into metrics. Mounts the generated **device catalog** (`config/catalog.yaml`) so flow records get the same `device_name` and tags as SNMP.
- **`ktranslate_snmp_<group>`** — one long-running SNMP poller per credential group. Each reads a settings file from `config/` plus a separately-managed device list from `state/`. The generated poller config sets `global.user_tags.snmp_group: <GROUP>` so every SNMP series from that poller carries credential-group metadata (exported as **`tags_snmp_group`** on OTLP series in Grafana Cloud).
- **`discover_<group>`** — one short-lived discovery container per credential group. Runs on a schedule, finds devices, writes the list back to `state/`, and tells the matching poller to reload.
- **`ktranslate_syslog`** — collects syslog and forwards it as logs. Uses the same device catalog as flow for consistent naming/tags.
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

A deployment is **N credential groups**, one declarative file each under `groups/<name>.env`. A generator script (`scripts/generate-groups.sh`) reads those files and renders the per-group config yamls plus a compose service fragment. Adding a credential group is a one-file operation followed by a re-run of the generator — no compose or script edits. A **single device** is just the degenerate case: one `cidr` group with one target.

Each group picks its own **`DISCOVERY_SOURCE`** (`cidr` or `netbox`), so one deployment can mix a CIDR-scanned vendor and a NetBox-sourced vendor side by side. See [configuration.md](configuration.md) for the group reference.

> This repo previously used separate branches for these shapes (`main` = single poller, `multicontainer_example` = per-group CIDR discovery, `multicontainer_netbox` = per-group NetBox discovery). They have all been consolidated into this one model on `main`; the old branch tips are preserved as `archive/*` tags.

## Why discovery and polling are split

The split between discovery and polling lets **git stay the source of truth** for credentials, scan ranges, and polling rules, while letting **the network itself be the source of truth** for which devices currently exist. Discovery writes are atomic and reversible; polling configs are mounted read-only and never mutated.

## Compose interpolation vs. per-service `env_file:`

There are two distinct mechanisms in Docker Compose for "loading variables from a file," and the distinction matters if you extend this setup:

- **Compose-level interpolation (what this repo uses)** — variables in `.env` are substituted into the compose file *at parse time*, before any container is created. They become whatever you reference them as (`environment:`, `command:`, ports, image tags, etc.). The container itself never sees `.env`; it only sees what you explicitly hand it via the `environment:` block.
- **Per-service `env_file:`** — adding `env_file: [.env]` to a service block injects the file's contents *into that container's environment* at runtime. Use this when a container expects to read a variable it wasn't explicitly given via `environment:` — for example, a third-party image that auto-reads `MY_API_KEY` from `os.environ`. None of the containers in this repo need that, so we rely on interpolation alone.

The `config.alloy` file is already wired to the `GC_OTLP_*` env vars; you should not need to touch it unless you have non-ktranslate changes to make. Keep the live `compose-base.yaml` Alloy volume as `source: ./config.alloy` (not a host-specific absolute path). If Grafana Explore is empty, walk the hops in [troubleshooting/bring-up.md](../troubleshooting/bring-up.md): discovery YAML → Alloy metrics on host `:12346` → PromQL `kentik_snmp_CPU` (not `kentik_snmp_DeviceMetrics`).

## Kubernetes is another runtime, not another model

`make k8s-up` applies the same generated poller/discovery/catalog YAML as Deployments, a PVC for `state/devices-*.yaml`, and a CronJob instead of host cron. Alloy still forwards to Grafana Cloud. Groups, `KTRANS_HOST`, and the dashboards do not change.

Kubernetes does **not** change the hard parts of talking to network gear (stable destination IPs, one poller per device list, UDP loss on restart). Those are called out in [k8s/LIMITATIONS.md](../k8s/LIMITATIONS.md). Operator steps: [kubernetes.md](kubernetes.md).
