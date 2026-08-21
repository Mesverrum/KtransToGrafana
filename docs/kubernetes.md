# Kubernetes runtime

[← back to README](../README.md) · **Limitations:** [k8s/LIMITATIONS.md](../k8s/LIMITATIONS.md)

This is another **apply target** for the same workflow as Compose — not a fork and not a different collector model. You still declare credential groups under `groups/`, run the generator, discover devices, and poll. Alloy still forwards to Grafana Cloud.

```
.env + groups/*.env
        │
        ▼
   make generate          ← poller YAML, catalog, Alloy (unchanged)
        │
   ┌────┴────┐
   ▼         ▼
make up    make k8s-up
Compose    Deployments + CronJob + Secret + PVC
```

Read [k8s/LIMITATIONS.md](../k8s/LIMITATIONS.md) before you point production gear at a cluster. The short version: stamp a **stable IPv4** on the device, keep the device list on a **PVC**, scale **wide** (more groups) or **up** (more CPU/RAM), and treat redundancy as a **second site** plus dual export — not `replicas: 2`.

## When to use this

Use `k8s/` when you already operate Kubernetes (k3s, GKE, EKS, AKS) and want collectors scheduled there.

Stay on Compose when the requirement is “one Linux host with a stable address and cron.” That path is simpler and has the same availability shape (one process, one IP).

This repo’s companion lab (`network-o11y-demo`) has its own generated k3s path for a Clos fabric. Do not copy those manifests here — they assume hostPath, SR Linux profiles, and gnmic.

## Prerequisites

- `kubectl` pointed at the cluster (a local Docker daemon is **not** required)
- The same `.env` and `groups/*.env` as Compose (`GC_OTLP_*` required)
- A node you are willing to **pin** (hostNetwork default) **or** a **reserved** LoadBalancer IP
- A StorageClass that can provide a `ReadWriteOnce` 1Gi volume on that node

## `.env` knobs

All optional except as noted. Defaults are what we consider the least-surprising production starting point.

| Variable | Default | Meaning |
|----------|---------|---------|
| `K8S_NAMESPACE` | `ktrans` | Namespace for all objects |
| `K8S_INGRESS_MODE` | `hostnetwork` | `hostnetwork` (device target = node IP) or `loadbalancer` (device target = reserved VIP) |
| `K8S_COLLECTOR_NODE` | empty | `kubernetes.io/hostname` pin. **Set this** in hostNetwork mode. |
| `K8S_COLLECTOR_IP` | empty | The IPv4 you will type on the device (node address or VIP). Written into the identity ConfigMap. |
| `K8S_LOADBALANCER_IP` | `$K8S_COLLECTOR_IP` | Reserved VIP for `loadbalancer` mode |
| `K8S_PRESERVE_SOURCE_IP` | `1` | `externalTrafficPolicy: Local` on inbound Services. Set `0` only if you accept SNATed sources. |
| `K8S_ALLOY_MODE` | `cluster` | Alloy as a ClusterIP Service. Set `hostnetwork` if your CNI cannot reach ClusterIP from `hostNetwork` pods; collectors then use `127.0.0.1:4317`. |
| `K8S_STORAGE_CLASS` | cluster default | PVC class. Must remount on the pinned node. |
| `K8S_STORAGE_SIZE` | `1Gi` | PVC request |
| `K8S_DISCOVER_SCHEDULE` | `0 */6 * * *` | CronJob schedule; groups are staggered by +5 minutes |

`KTRANS_HOST`, `KTRANSLATE_IMAGE`, `ALLOY_IMAGE`, `NF_SOURCE`, `SYSLOG_SOURCE`, `NETBOX_*`, and AWS keys behave as on Compose. OTLP credentials become the `grafana-otlp` Secret and are **not** written into `k8s/generated/`.

Poller and discovery ConfigMaps **do** contain SNMP communities / v3 fields, the same way `config/poller-*.yaml` does on the Compose host. Restrict RBAC on the namespace accordingly.

## Bring-up

```
cp .env.sample .env
# set GC_OTLP_* and the K8S_* pin (node + IP)

cp groups/onboarding.env.sample groups/onboarding.env
# TARGETS, credentials, unique TRAP_PORT / METALISTEN_PORT

make generate-k8s          # also runs generate-groups.sh
make k8s-up                # secrets + kubectl apply -k k8s/generated
make k8s-discover GROUP=onboarding
```

`make k8s-up` prints the identity ConfigMap (`stamp_on_gear`). Copy those **IPs and ports** into trap-groups, flow exporters, and syslog remote-servers. Do not use Kubernetes DNS names on the device.

One-shot discovery is `make k8s-discover GROUP=<name>` (a Job cloned from the CronJob). Scheduled discovery uses the same containers.

## What gets created

| Object | Role |
|--------|------|
| Secret `grafana-otlp` | Cloud OTLP URL / account / token |
| Secret `ktrans-optional` | NetBox + AWS keys (optional refs) |
| PVC `ktrans-state` | `devices-*.yaml` and discovery runtime files |
| ConfigMaps | poller/discovery YAML, catalog, Alloy, scripts, **collector identity** |
| Deployment `alloy` | OTLP fan-in → Grafana Cloud (`replicas: 1`) |
| Deployment `ktranslate-flow` / `ktranslate-syslog` / `ktranslate-snmp-<group>` | One listener each, `hostNetwork` or ClusterIP+LB |
| Deployment `flow-dns` | In-cluster PTR for flow `src_host` / `dst_host` |
| CronJob `discover-<group>` | CIDR or NetBox scan → publish onto the PVC |
| Job `ktrans-state-bootstrap` | Empty `{}` stubs so pollers can start |
| Service (loadbalancer mode only) | Per-listener LoadBalancer with reserved VIP |
| PDB | `maxUnavailable: 1` — a drain **will** drop UDP |

Reload after discovery does **not** use `kubectl exec`. Pollers share a process namespace with a `state-watch` sidecar that SIGUSR2’s ktranslate when `devices-<group>.yaml` changes. Flow/syslog watch `devices-changed.flag` and restart.

## Inbound modes

**hostNetwork (default).** Collectors bind the node’s ports. Stamp `K8S_COLLECTOR_IP`. Pin `K8S_COLLECTOR_NODE` so the scheduler cannot move the address. Node death moves the IP unless you fail a VIP onto another node.

**loadbalancer.** Collectors are normal pods. Stamp `K8S_LOADBALANCER_IP`. Keep `K8S_PRESERVE_SOURCE_IP=1` and still pin the node so `externalTrafficPolicy: Local` has a pod on a node the LB health-checks. Cloud implementations differ in whether one VIP can front several UDP Services — check your MetalLB / NLB docs; the identity ConfigMap is still the source of truth for what you type on the device.

Alloy stays ClusterIP unless `K8S_ALLOY_MODE=hostnetwork`. Devices never talk to Alloy.

## Tear-down

```
make k8s-down          # deletes generated objects; keeps the PVC
make k8s-down-wipe     # also deletes PVC ktrans-state (device list is gone)
```

## Dashboards and verification

Unchanged from Compose. Push [dashboards/](../dashboards/) with `python3 scripts/push-dashboards.py`. Verify with `kentik_snmp_PollingHealth` / `kentik_snmp_CPU` and `network_io_by_flow` — see [grafana.md](grafana.md).

Filter multiple collector sites with `deployment_host` (`KTRANS_HOST`) and credential groups with `tags_snmp_group`.
