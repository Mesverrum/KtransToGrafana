# Contributing / maintenance notes

A few conventions keep this repo consistent. Most are non-obvious, so they're
written down here rather than left to memory.

## Docs: README is a thin index, depth lives in `docs/`

The [README](README.md) is deliberately minimal — intro, prerequisites, an
onboarding quickstart (a range, or one device as `TARGETS=<ip>/32`), verification, and a "Going further" index. All depth
lives in `docs/` (`architecture.md`, `configuration.md`, `operations.md`,
`grafana.md`) and `troubleshooting/` (`bring-up.md` for first-time hops,
`snmp.md` for snmpwalk).

**When you add a capability, update it in two places:** the relevant `docs/`
file *and* the README "Going further" list (a one-line pointer, ideally deep-
linked to the new section). A feature that's only in `docs/` is invisible from
the front page; a feature that bloats the README breaks the fast path. If you
add a new `docs/` file, add a bullet for it in the README index too.

## Config is generated — edit the inputs, not the outputs

A deployment is `groups/*.env` rendered by `scripts/generate-groups.sh` through
the files in `templates/` (`poller.yaml.tmpl`, `discovery.yaml.tmpl`,
`compose-poller.yaml.tmpl`, `compose-discover.yaml.tmpl`). **Never hand-edit the generated artifacts** (`config/`,
`compose-groups.generated.yaml`, `compose-limits.generated.yaml`,
`k8s/generated/`) — they're overwritten on every `make generate` /
`make generate-k8s`. To change rendering, edit the templates or the generator.
Run `make generate` after any template/group/generator change. Kubernetes is
another apply target (`scripts/generate-k8s.py`), not a second product — keep
the Compose and k8s paths on the same group files. Limitation copy lives in
`k8s/LIMITATIONS.md`; don't bury those in a comment in the YAML.

When touching the generator or templates:

- Keep the simple cases working — a plain single-credential `v2c` or `v3` group,
  and onboarding with one `TARGETS=<ip>/32`, must still render valid YAML.
- Test every mode you touched actually renders **valid YAML**: copy the relevant
  `groups/*.env.sample` to `groups/<name>.env`, run `make generate`, and check
  the output with `yq -e '.' config/discovery-<name>.yaml` (and the poller).
  Clean up the temp group + `config/` afterwards.

## Device-list split is YAML, not a new script

`scripts/split-devices.py` routes a discovery list into `ROLE=poll` files.
Default is **dynamic vendor** from `mib_profile` (provisions `groups/*.env`).
Static matchers live under `examples/vendor-split/recipes/`. When you add a
matcher, add a `--self-test` case — do not grow a family of `split-devices-by-*.py`
scripts.

## Group `.env` files are shell-sourced

The generator `source`s each `groups/*.env`, so **quote any value containing
spaces or shell characters** (e.g. `SNMP_V2_COMMUNITY="a, b ,c"`). An unquoted
space silently breaks sourcing and aborts the whole run.

## Samples are the source of truth

The tracked `*.sample` files are what ships. `.env` and `groups/*.env` are
copied once (git-ignored) because they hold secrets and site-specific ranges.

`config.alloy.sample` and `compose-base.yaml.sample` are **runtime files** —
do not copy them. `make up` uses them directly so `git pull` updates Alloy and
Compose. Customize with gitignored `compose.override.yaml` — walkthrough:
[docs/architecture.md § Customizing Alloy and Compose](docs/architecture.md#customizing-alloy-and-compose).

If you add a new secret/runtime file, make sure `.gitignore` covers it.

## One branch

Everything lives on `main`. The old per-shape branches (`multicontainer_example`,
`multicontainer_netbox`) were consolidated in and are preserved as `archive/*`
tags — don't recreate them; add a `DISCOVERY_SOURCE` or a group instead.
