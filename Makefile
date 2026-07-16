.PHONY: up down logs preflight detect-net limits limits-show help

COMPOSE := docker compose -f compose.yaml -f compose-limits.generated.yaml

help:
	@echo "make preflight    Check that .env / snmp.yaml / config.alloy are ready"
	@echo "make detect-net   Append HOST_NET=<your-default-interface> to .env"
	@echo "make limits       Compute per-container memory limits from host RAM"
	@echo "make limits-show  Print the limits plan without writing the overlay"
	@echo "make up           Run preflight + limits, then docker compose up -d"
	@echo "make down         docker compose down"
	@echo "make logs         Tail logs from all containers"

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
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f
