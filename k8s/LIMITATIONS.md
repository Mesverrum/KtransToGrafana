# Kubernetes limitations — read this before the quickstart

A customer conversation that keeps coming back: *“We’ll put ktranslate on the cluster so the destination is HA and we don’t have to care about IPs.”* Kubernetes does **not** make that true for SNMP, traps, NetFlow, or syslog. This folder tries to be honest about four problems and to mitigate each one as far as the protocols allow.

The Compose path on one Linux host is still the default. This `k8s/` runtime is the same workflow (groups → generate → discover → poll) with a different apply target. It is not a second product and not an HA story.

---

## 1. Ephemeral destination IP (gear that cannot do DNS)

**The problem.** Routers and switches send traps, NetFlow, sFlow, and syslog to a **literal IPv4 address** typed into the device. Most platforms will not follow a DNS name, and they will not retry a new address when a Kubernetes Service or pod IP changes. A ClusterIP, a default cloud LoadBalancer, or an unpinned `hostNetwork` pod is an ephemeral destination. The first collector restart that lands on another node looks like “telemetry died” from the NOC’s point of view.

**What we will not do.** We will not tell you to point gear at `ktranslate-flow.ktrans.svc.cluster.local`. In-cluster DNS is for **ktranslate → Alloy** only.

**What this runtime does.**

| Mode | Destination you stamp on the device | How it stays still |
|------|--------------------------------------|--------------------|
| `K8S_INGRESS_MODE=hostnetwork` (default) | The **node’s** address (`K8S_COLLECTOR_IP`) | Pods are `hostNetwork: true` and **pinned** with `K8S_COLLECTOR_NODE`. The IP is the node, not the pod. |
| `K8S_INGRESS_MODE=loadbalancer` | A **reserved VIP** (`K8S_LOADBALANCER_IP`) | `Service type: LoadBalancer` with that VIP. Use `K8S_PRESERVE_SOURCE_IP=1` (`externalTrafficPolicy: Local`) so flow `sampler_address` and trap source IPs are not SNATed. |

After `make k8s-up`, read `kubectl -n ktrans get cm ktrans-collector-identity -o yaml` and `k8s/generated/COLLECTOR-ENDPOINTS.md`. Those are the only addresses that belong on the device.

**What still hurts.**

- **Node death in hostNetwork mode** — the destination IP dies with the node. Fail the VIP (keepalived / MetalLB speaker / cloud LB) onto another node, or treat this as a site collector and fail *the site*.
- **Unpinned hostNetwork** — if you skip `K8S_COLLECTOR_NODE`, the scheduler can move the pod and the IP your gear has is wrong. The generator warns; it will not invent a stable IP for you.
- **Ephemeral cloud LB** — if you skip `K8S_LOADBALANCER_IP`, the cloud assigns an address that can change when the Service is recreated. Reserve the VIP first.
- **`externalTrafficPolicy: Cluster`** — kube-proxy SNATs the source. Flow and trap identity get the node IP, not the device. Leave `K8S_PRESERVE_SOURCE_IP=1` unless you have no other choice; then pin the node anyway (`Local` only works if the pod is on a node the LB actually hits).

**Customer phrasing that works:** “The collector has one IPv4 address. We write that address on the gear. Kubernetes is allowed to restart the process behind that address. It is not allowed to change the address.”

---

## 2. Managing “state” in the devices file

**The problem.** Discovery writes `state/devices-<group>.yaml`. The poller `@`-includes that file. Flow and syslog `@`-include the same lists via `config/catalog.yaml`. That file is **not** git, **not** a ConfigMap (1 MiB limit, no atomic rename, no SIGUSR2), and **not** something you want to hand-edit in the cluster.

A failed discovery that publishes `devices: {}` wipes the poller. A poller that never reloads keeps talking to last month’s estate. Two writers on the same file corrupt it.

**What this runtime does.**

- A **PVC** (`ktrans-state`, `ReadWriteOnce`) is the only writable copy of `devices-*.yaml`.
- Discovery is a **CronJob** (and `make k8s-discover GROUP=…`) that:
  1. Copies the generated discovery config onto the PVC (git remains source of truth for *how* to scan).
  2. Runs ktranslate `-snmp_discovery=true`.
  3. Publishes with the same rules as `scripts/run-discovery.sh`: **empty scan keeps the previous list**; write is atomic (`mv`).
- Pollers mount the PVC **read-only**. An init container (and the `state-watch` sidecar) unions each device's `discovered_mibs` into `/state/poller-<group>.runtime.yaml` so vendor tables are polled without editing the ConfigMap. `state-watch` then sends **SIGUSR2** when that group's device file changes — no `kubectl exec`, no extra RBAC.
- Flow and syslog watch a `devices-changed.flag` and **restart** (they need a full re-read of the catalog), same as Compose `restart`.
- A bootstrap Job seeds empty `{}` stubs so pollers can start before the first scan.

**What still hurts.**

- **RWO + one node.** The PVC and the `hostNetwork` pin want the **same** node. That is intentional. “HA storage” (RWX / EFS) does not give you two active pollers; it only lets a replacement pod attach after a move. If you need the pod to reschedule after node death, use a StorageClass that can remount on another node *and* move the destination IP (loadbalancer mode), or accept a restore from backup onto a new node.
- **Backup the PVC.** The estate lives there. Snapshot it. Git will not save you.
- **Do not kubectl-edit** `devices-*.yaml` as the long-term process. If you must hotfix one device, treat it like editing `state/` on the Compose host: you now own that file until the next discovery run (`replace_devices: true` on the discovery config will overwrite it).
- **ConfigMaps for device lists** were considered and rejected. Size, reload, and “empty publish wipes production” are worse there than on a filesystem.

**Customer phrasing that works:** “Git owns credentials and CIDRs. The network owns the current device list and which MIBs those devices speak. The PVC is the network’s notebook. Discovery is allowed to update it; a blank page is not an update.”

---

## 3. Scale up vs scale wide

**The problem.** App teams reach for `replicas: 3` and an HPA. SNMP polling and UDP listeners do not shard. Two replicas of the same poller **double the walk load** on every device and both try to bind the same trap port. Two flow listeners on the same port split or collide; they do not “load-balance conversations.”

**What this runtime does.**

- Every collector Deployment is **`replicas: 1`** with **`strategy: Recreate`**. We will not generate an HPA.
- **Scale wide** = more `groups/*.env` files (credential domain, vendor, or blast-radius). Each group is one poller Deployment and one trap port. That is the same model as Compose.
- **Scale up** = raise CPU/memory on that one poller (`resources.limits` in the generated YAML, or edit after generate if you must). ktranslate is a process, not a stateless replica set. Starting numbers: [architecture.md — Sizing](../docs/architecture.md#sizing-rule-of-thumb) (about **1 CPU + 1 GiB per 500 average SNMP devices**, or **per 1000 events/s** of flow, traps, or syslog).
- Split a group when poll duration exceeds `POLL_INTERVAL_SEC`, when you want a smaller blast radius, or when credentials differ. Do not split “for Kubernetes.”

**What still hurts.**

- There is no clever way to run 50k interfaces at 15s on one pod. Split groups or lengthen the interval.
- Flow cardinality (`--rollup_top_k`, `--rollups=…`) is still the cost knob. Replicas will not fix a wide rollup.
- `PodDisruptionBudget` here is honest: `maxUnavailable: 1` on a single replica means **a drain drops UDP**. We will not set `maxUnavailable: 0` and pretend the cluster can evict you for free.

**Customer phrasing that works:** “Wide is more credential groups. Up is a bigger box for one group. Sideways copies of the same listener are a self-inflicted outage.”

---

## 4. “HA” and redundancy

**The problem.** People hear “Kubernetes” and picture two zones, a Service, and no downtime. For this collector:

| Pattern | What actually happens |
|---------|------------------------|
| Two ready SNMP pollers, same device list | Double polling. Devices, ACLs, and SNMPv3 USM engines get unhappy. |
| Two ready trap/flow listeners, same port, no shared VIP | Half the packets miss, or the second pod cannot bind. |
| RollingUpdate on `hostNetwork` | A second pod is created *before* the first dies and cannot bind the port (we already hit this). Hence **Recreate**. |
| Recreate / node drain | Brief **UDP loss**. Gear does not queue NetFlow the way a TCP client retries. |
| ClusterIP Service in front of one pod | Stable only inside the cluster. Devices never see it. |

**What this runtime does.**

- Restart HA: kubelet restarts the process. The destination IP stays if you pinned it (node IP or reserved VIP).
- Recreate strategy so two pods never fight for UDP 9995 / 1514 / trap ports.
- `KTRANS_HOST` still suffixes `service.name` and Alloy still stamps `deployment.host`, so **two sites** stay separable in Grafana.

**What we recommend instead of “k8s HA”.**

1. **Two collector sites** (two `KTRANS_HOST` values, two destination IPs). Many platforms can send traps and NetFlow to **two destinations**. That is real redundancy: either site can be down.
2. **One active poller per estate.** Do not active-active the walk. A warm standby is `replicas: 0` on another node/cluster, or a second site that only *receives* traps/flow until you fail polling over.
3. **VIP failover** (keepalived, MetalLB, cloud NLB with a reserved IP) if you need the *same* address to move. The process is still one replica; the address is what the gear believes in.
4. Accept **seconds of UDP loss** on restart. Alert on `kentik_snmp_PollingHealth` and trap/flow rate, not on pod count.

**What still hurts.**

- There is no multi-AZ active-active SNMP poller in this design. Anyone who sells you that is selling double load.
- A reserved VIP plus `externalTrafficPolicy: Local` still needs the pod on a node the LB is willing to hit. Pin the node or use a DaemonSet of *speakers*, not a DaemonSet of pollers.
- Compose on a VM already had the same availability shape (one host). Kubernetes adds scheduling and CronJobs. It does not add a second packet path.

**Customer phrasing that works:** “HA for network telemetry is two places the device already knows how to send. It is not two pods behind one Service.”

---

## Quick decision table

| If you need… | Do this | Do not do this |
|--------------|---------|----------------|
| A destination the device can type | Pin `K8S_COLLECTOR_IP` + node, or reserve `K8S_LOADBALANCER_IP` | ClusterIP, DNS name, ephemeral LB |
| Discovery that does not wipe production | CronJob + `publish-devices.sh` (empty = keep previous) | Replace the PVC with a hand-applied ConfigMap |
| More capacity | More groups, or more CPU/RAM on one poller | `kubectl scale deploy --replicas=3` |
| Survive a site/collector loss | Second `KTRANS_HOST` + dual export on the device | Two ready pollers on the same list |
| Survive a process crash | `replicas: 1` + Recreate + pinned IP | RollingUpdate + hostNetwork |

When in doubt, run Compose on a small VM that owns a stable address. Use this folder when you already operate Kubernetes and want the **same** generate/discover workflow there — not because the cluster will invent a better collector.