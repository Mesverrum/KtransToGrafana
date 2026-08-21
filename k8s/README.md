# Kubernetes runtime

Same KtransToGrafana workflow as Docker Compose: `groups/*.env` → `make generate` → discover → poll → Alloy → Grafana Cloud. This directory is the **apply target**, not a fork.

**Read [LIMITATIONS.md](LIMITATIONS.md) first.** Kubernetes does not give network gear a DNS name, a shared-nothing device inventory, or active-active SNMP. The four issues we keep hearing from customers — ephemeral destination IPs, `devices-*.yaml` state, scale-up vs scale-wide, and “HA” — are documented there with what this runtime actually does about each one.

Generated manifests land in `generated/` (gitignored). Do not hand-edit them; change `groups/*.env` / `.env` and re-run `make generate-k8s`.

## What we pinned down

| Issue | Default in this folder |
|-------|------------------------|
| Gear cannot follow DNS | Stamp **`K8S_COLLECTOR_IP`** (node) or **`K8S_LOADBALANCER_IP`** (reserved VIP). Identity ConfigMap + `generated/COLLECTOR-ENDPOINTS.md`. |
| Device list is stateful | PVC `ktrans-state`. Discovery publishes atomically and **keeps the last good list** on an empty scan. Sidecar reload (SIGUSR2 / restart), no `kubectl exec`. |
| Scale | `replicas: 1`, `strategy: Recreate`. Wide = more groups. Up = more CPU/RAM. |
| Redundancy | Restart HA + optional second **site** (`KTRANS_HOST`) with dual export on the device. Not two ready pollers. |

## Quickstart

Prerequisites: a kubecontext, `kubectl`, and the same `.env` + `groups/*.env` you would use for Compose.

```
# 1. Same as Compose
cp .env.sample .env          # GC_OTLP_* plus the K8S_* block
cp groups/onboarding.env.sample groups/onboarding.env
# edit TARGETS / credentials

# 2. Pin the address your gear will use (hostNetwork default)
#    K8S_COLLECTOR_NODE = kubectl get nodes
#    K8S_COLLECTOR_IP   = that node's IPv4 (or a reserved VIP in loadbalancer mode)

make generate-k8s
make k8s-up                  # secrets from .env + kubectl apply -k k8s/generated
make k8s-discover GROUP=onboarding
```

Verify:

```
kubectl -n ktrans get pods
kubectl -n ktrans get cm ktrans-collector-identity -o yaml
```

Then in Grafana Cloud Explore:

```
count by (tags_snmp_group, device_name) (kentik_snmp_PollingHealth)
```

Full operator notes: [docs/kubernetes.md](../docs/kubernetes.md). Limitations and the customer wording: [LIMITATIONS.md](LIMITATIONS.md).

## Make targets

| Target | What it does |
|--------|----------------|
| `make generate-k8s` | `generate-groups.sh` + render `k8s/generated/` |
| `make k8s-up` | generate, create OTLP/optional secrets, apply |
| `make k8s-down` | `kubectl delete -k k8s/generated` (PVC is left unless you pass `--extra`) |
| `make k8s-discover GROUP=…` | one-shot Job from the group’s CronJob |

## Layout

```
k8s/
  README.md                 ← you are here
  LIMITATIONS.md            ← ephemeral IP, state, scale, HA
  scripts/                  ← state-watch, publish-devices, seed-state (mounted as a ConfigMap)
  generated/                ← kubectl apply -k  (gitignored)
```
