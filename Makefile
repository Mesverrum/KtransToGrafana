.PHONY: up up-demo down logs preflight generate bootstrap limits limits-show discover discover-all split-devices split-vendors flow-dns detect-net host generate-k8s k8s-up k8s-down k8s-down-wipe k8s-discover help

COMPOSE := docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml -f compose-limits.generated.yaml

# Resolve the per-host identifier that Alloy stamps onto all telemetry
# (deployment.host) and that suffixes every container's service.name. Prefer an
# explicit KTRANS_HOST in .env; if blank, fall back to the machine's hostname so
# each host self-identifies with no config. Exported so `docker compose` picks
# it up — a value in the process environment overrides a blank one in .env.
# scripts/host-id.sh holds the logic so the discovery cron job agrees with make.
# Invoke via bash so a clone without git executable bits still works (Windows
# zip / some git configs drop +x; ./scripts/foo.sh then fails with Permission denied).
KTRANS_HOST := $(shell bash scripts/host-id.sh 2>/dev/null)
export KTRANS_HOST

help:
	@echo "make preflight              Check that .env / groups / generated configs are ready"
	@echo "make generate               Render ALL groups/*.env (GROUP= is ignored — that is discover-only)"
	@echo "make bootstrap              Seed empty state/devices-<group>.yaml stubs so pollers can start"
	@echo "make limits                 Compute per-container memory limits from host RAM"
	@echo "make limits-show            Print the limits plan without writing the overlay"
	@echo "make up                     Preflight + bootstrap + flow-dns + limits + compose up (all groups; GROUP= ignored)"
	@echo "make up-demo                Same as 'up' plus the host-sflow demo overlay (instant flow data)"
	@echo "make down                   docker compose down"
	@echo "make logs                   Tail logs from all containers"
	@echo "make discover GROUP=cisco   Run a one-shot discovery for one group"
	@echo "make discover-all           Discover every ROLE=discover|both group; reload if any list changed"
	@echo "make split-devices          Split the latest scan (dynamic vendor by default); provision pollers; SIGUSR2"
	@echo "make split-vendors          Alias for split-devices"
	@echo "make flow-dns               Regenerate flow_dns PTR records from device catalog"
	@echo "make detect-net             Auto-fill HOST_NET in .env (only needed for the sflow overlay)"
	@echo "make host                   Print the deployment.host value this stack will use"
	@echo "make generate-k8s           Render k8s/generated/ from groups/*.env (see k8s/LIMITATIONS.md)"
	@echo "make k8s-up                 Secrets from .env + kubectl apply -k k8s/generated"
	@echo "make k8s-down               Delete generated objects; keep the devices PVC"
	@echo "make k8s-down-wipe          Delete generated objects and the devices PVC"
	@echo "make k8s-discover GROUP=…   One-shot in-cluster discovery Job"

preflight:
	@bash scripts/preflight.sh

generate:
	@if [ -n "$(GROUP)" ]; then echo "NOTE: GROUP=$(GROUP) is ignored. make generate renders every groups/*.env. GROUP= only applies to make discover." >&2; fi
	@bash scripts/generate-groups.sh

bootstrap:
	@mkdir -p state dnsmasq
	@for envfile in groups/*.env; do \
	  [ -f "$$envfile" ] || continue; \
	  group=$$(awk -F= '/^GROUP=/{print $$2; exit}' "$$envfile"); \
	  [ -z "$$group" ] && continue; \
	  if [ ! -f "state/devices-$$group.yaml" ]; then \
	    echo '{}' > "state/devices-$$group.yaml"; \
	    echo "seeded empty state/devices-$$group.yaml"; \
	  fi; \
	done
	@[ -f dnsmasq/hosts.generated.conf ] || echo '# pending refresh-flow-dns' > dnsmasq/hosts.generated.conf
	@[ -f dnsmasq/upstream.conf ] || echo 'server=host.docker.internal' > dnsmasq/upstream.conf

flow-dns:
	@bash scripts/refresh-flow-dns.sh

limits:
	@bash scripts/compute-limits.sh

limits-show:
	@bash scripts/compute-limits.sh --dry-run

up: preflight bootstrap flow-dns limits
	@if [ -n "$(GROUP)" ]; then echo "NOTE: GROUP=$(GROUP) is ignored. make up starts every groups/*.env. GROUP= only applies to make discover." >&2; fi
	@echo "deployment.host = $(KTRANS_HOST)"
	$(COMPOSE) up -d

# Same as `up` but layers in the optional host-sflow demo overlay so you get
# flow data immediately without a real netflow/sflow source configured yet.
up-demo: preflight bootstrap flow-dns limits
	@if [ -n "$(GROUP)" ]; then echo "NOTE: GROUP=$(GROUP) is ignored. make up-demo starts every groups/*.env. GROUP= only applies to make discover." >&2; fi
	@echo "deployment.host = $(KTRANS_HOST)"
	$(COMPOSE) -f compose-sflow.yaml up -d

host:
	@echo "$(KTRANS_HOST)"

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

discover:
	@test -n "$(GROUP)" || { echo "ERROR: pass GROUP=<name>, e.g. make discover GROUP=cisco" >&2; exit 1; }
	@bash scripts/run-discovery.sh $(GROUP)

discover-all:
	@bash scripts/run-discovery-all.sh

split-devices split-vendors:
	@bash scripts/apply-device-split.sh

# Auto-detect the host's default interface and write it to .env as HOST_NET.
# Only needed if you use the host-sflow demo overlay (make up-demo).
detect-net:
	@test -f .env || { echo "ERROR: .env doesn't exist yet. Run: cp .env.sample .env" >&2; exit 1; }
	@grep -v '^HOST_NET=' .env > .env.tmp && mv .env.tmp .env
	@echo "HOST_NET=$$(ip -4 route show default | awk '/^default/ {print $$5; exit}')" >> .env
	@echo "set HOST_NET in .env"

generate-k8s: generate
	@python3 scripts/generate-k8s.py --skip-generate

# Does not run `preflight` — that check requires a local Docker daemon.
# deploy-k8s.sh validates .env / OTLP and regenerates manifests.
k8s-up:
	@./scripts/deploy-k8s.sh

k8s-down:
	@kubectl delete -k k8s/generated --ignore-not-found
	@echo "PVC ktrans-state was kept (device lists). Wipe with: make k8s-down-wipe"

k8s-down-wipe: k8s-down
	@ns="$${K8S_NAMESPACE:-ktrans}"; \
	  if [ -f .env ]; then ns="$$(awk -F= '/^K8S_NAMESPACE=/{print $$2; exit}' .env)"; ns="$${ns:-ktrans}"; fi; \
	  kubectl -n "$$ns" delete pvc ktrans-state --ignore-not-found
	@echo "deleted PVC ktrans-state"

k8s-discover:
	@test -n "$(GROUP)" || { echo "ERROR: pass GROUP=<name>, e.g. make k8s-discover GROUP=cisco" >&2; exit 1; }
	@./scripts/k8s-discover.sh $(GROUP)
