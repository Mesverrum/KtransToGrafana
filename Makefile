.PHONY: up down logs preflight detect-net limits limits-show host help

COMPOSE := docker compose -f compose.yaml -f compose-limits.generated.yaml

# Resolve the per-host identifier that Alloy stamps onto all telemetry
# (deployment.host) and that suffixes every container's service.name. Prefer an
# explicit KTRANS_HOST in .env; if blank, fall back to the machine's hostname so
# each host self-identifies with no config. Exported so `docker compose` picks
# it up — a value in the process environment overrides a blank one in .env.
KTRANS_HOST := $(shell ./scripts/host-id.sh 2>/dev/null)
export KTRANS_HOST

help:
	@echo "make preflight    Check that .env / snmp.yaml / config.alloy are ready"
	@echo "make detect-net   Append HOST_NET=<your-default-interface> to .env"
	@echo "make limits       Compute per-container memory limits from host RAM"
	@echo "make limits-show  Print the limits plan without writing the overlay"
	@echo "make up           Run preflight + limits, then docker compose up -d"
	@echo "make down         docker compose down"
	@echo "make logs         Tail logs from all containers"
	@echo "make host         Print the deployment.host value this stack will use"

preflight:
	@./scripts/preflight.sh

detect-net:
	@test -f .env || { echo "ERROR: .env doesn't exist yet. Run: cp .env.sample .env" >&2; exit 1; }
	@grep -v '^HOST_NET=' .env > .env.tmp && mv .env.tmp .env
	@echo "HOST_NET=$$(ip -4 route show default | awk '/^default/ {print $$5; exit}')" >> .env
	@echo "set HOST_NET in .env"

limits:
	@./scripts/compute-limits.sh

limits-show:
	@./scripts/compute-limits.sh --dry-run

up: preflight limits
	@echo "deployment.host = $(KTRANS_HOST)"
	$(COMPOSE) up -d

host:
	@echo "$(KTRANS_HOST)"

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f
