# Architecture

[← back to README](../README.md)

This example deploys a small set of containers via Docker Compose:

- **`ktranslate_flow`** — receives netflow data (netflow 5/9, sflow, ipfix, nbar, pan, etc.) and converts it to OTEL metrics via configurable rollups.
- **`ktranslate_snmp_<group>`** — one long-running SNMP poller per credential group. Each reads a static config file from `config/` plus a separately-managed device list from `state/`.
- **`discover_<group>`** — one short-lived discovery container per credential group. Runs on a schedule, writes discovered devices back to `state/`, and signals the matching poller to reload.
- **`ktranslate_syslog`** — collects syslog and forwards as OTEL logs.
- **`alloy`** — a stripped-down Grafana Alloy agent that forwards all OTLP traffic from the above to Grafana Cloud.

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

The `config.alloy` file is already wired to the `GC_OTLP_*` env vars; you should not need to touch it unless you have non-ktranslate changes to make.
