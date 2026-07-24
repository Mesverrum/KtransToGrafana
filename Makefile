.PHONY: up up-demo down logs preflight generate bootstrap limits limits-show discover discover-all detect-net host help

COMPOSE := docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml -f compose-limits.generated.yaml

# Resolve the per-host identifier that Alloy stamps onto all telemetry
# (deployment.host) and that suffixes every container's service.name. Prefer an
# explicit KTRANS_HOST in .env; if blank, fall back to the machine's hostname so
# each host self-identifies with no config. Exported so `docker compose` picks
# it up — a value in the process environment overrides a blank one in .env.
# scripts/host-id.sh holds the logic so the discovery cron job agrees with make.
KTRANS_HOST := $(shell ./scripts/host-id.sh 2>/dev/null)
export KTRANS_HOST

help:
	@echo "make preflight              Check that .env / groups / generated configs are ready"
	@echo "make generate               Render configs and compose-groups.generated.yaml from groups/*.env"
	@echo "make bootstrap              Seed empty state/devices-<group>.yaml stubs so pollers can start"
	@echo "make limits                 Compute per-container memory limits from host RAM"
	@echo "make limits-show            Print the limits plan without writing the overlay"
	@echo "make up                     Run preflight + bootstrap + limits, then docker compose up -d"
	@echo "make up-demo                Same as 'up' plus the host-sflow demo overlay (instant flow data)"
	@echo "make down                   docker compose down"
	@echo "make logs                   Tail logs from all containers"
	@echo "make discover GROUP=cisco   Run a one-shot discovery for one group"
	@echo "make discover-all           Discover every group; reload catalog consumers if any list changed"
	@echo "make detect-net             Auto-fill HOST_NET in .env (only needed for the sflow overlay)"
	@echo "make host                   Print the deployment.host value this stack will use"

preflight:
	@./scripts/preflight.sh

generate:
	@./scripts/generate-groups.sh

bootstrap:
	@mkdir -p state
	@for envfile in groups/*.env; do \
	  [ -f "$$envfile" ] || continue; \
	  group=$$(awk -F= '/^GROUP=/{print $$2; exit}' "$$envfile"); \
	  [ -z "$$group" ] && continue; \
	  if [ ! -f "state/devices-$$group.yaml" ]; then \
	    echo '{}' > "state/devices-$$group.yaml"; \
	    echo "seeded empty state/devices-$$group.yaml"; \
	  fi; \
	done

limits:
	@./scripts/compute-limits.sh

limits-show:
	@./scripts/compute-limits.sh --dry-run

up: preflight bootstrap limits
	@echo "deployment.host = $(KTRANS_HOST)"
	$(COMPOSE) up -d

# Same as `up` but layers in the optional host-sflow demo overlay so you get
# flow data immediately without a real netflow/sflow source configured yet.
up-demo: preflight bootstrap limits
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
	@./scripts/run-discovery.sh $(GROUP)

discover-all:
	@./scripts/run-discovery-all.sh

# Auto-detect the host's default interface and write it to .env as HOST_NET.
# Only needed if you use the host-sflow demo overlay (make up-demo).
detect-net:
	@test -f .env || { echo "ERROR: .env doesn't exist yet. Run: cp .env.sample .env" >&2; exit 1; }
	@grep -v '^HOST_NET=' .env > .env.tmp && mv .env.tmp .env
	@echo "HOST_NET=$$(ip -4 route show default | awk '/^default/ {print $$5; exit}')" >> .env
	@echo "set HOST_NET in .env"
