# Contributing / maintenance notes

A few conventions keep this repo consistent. Most are non-obvious, so they're
written down here rather than left to memory.

## Docs: README is a thin index, depth lives in `docs/`

The [README](README.md) is deliberately minimal — intro, prerequisites, a
single-device quickstart, verification, and a "Going further" index. All depth
lives in `docs/` (`architecture.md`, `configuration.md`, `operations.md`,
`grafana.md`).

**When you add a capability, update it in two places:** the relevant `docs/`
file *and* the README "Going further" list (a one-line pointer, ideally deep-
linked to the new section). A feature that's only in `docs/` is invisible from
the front page; a feature that bloats the README breaks the fast path. If you
add a new `docs/` file, add a bullet for it in the README index too.

## Config is generated — edit the inputs, not the outputs

A deployment is `groups/*.env` rendered by `scripts/generate-groups.sh` through
the files in `templates/`. **Never hand-edit the generated artifacts** (`config/`,
`compose-groups.generated.yaml`, `compose-limits.generated.yaml`,
`k8s/generated/`) — they're overwritten on every `make generate` /
`make generate-k8s`. To change rendering, edit the templates or the generator.
Run `make generate` after any template/group/generator change. Kubernetes is
another apply target (`scripts/generate-k8s.py`), not a second product — keep
the Compose and k8s paths on the same group files. Limitation copy lives in
`k8s/LIMITATIONS.md`; don't bury those in a comment in the YAML.

When touching the generator or templates:

- Keep the simple cases working — a plain single-credential `v2c` or `v3` group,
  and a single-device `cidr` group, must render exactly as before.
- Test every mode you touched actually renders **valid YAML**: copy the relevant
  `groups/*.env.sample` to `groups/<name>.env`, run `make generate`, and check
  the output with `yq -e '.' config/discovery-<name>.yaml` (and the poller).
  Clean up the temp group + `config/` afterwards.

## Group `.env` files are shell-sourced

The generator `source`s each `groups/*.env`, so **quote any value containing
spaces or shell characters** (e.g. `SNMP_V2_COMMUNITY="a, b ,c"`). An unquoted
space silently breaks sourcing and aborts the whole run.

## Samples are the source of truth

The tracked files are the `*.sample` versions; the live copies (`.env`,
`config.alloy`, `compose-base.yaml`, `groups/*.env`, `state/*.yaml`) are
git-ignored. Edit the `.sample` when you want a change to ship. If you add a new
runtime file, make sure `.gitignore` covers it.

## One branch

Everything lives on `main`. The old per-shape branches (`multicontainer_example`,
`multicontainer_netbox`) were consolidated in and are preserved as `archive/*`
tags — don't recreate them; add a `DISCOVERY_SOURCE` or a group instead.
