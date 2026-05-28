.PHONY: up down logs preflight detect-net help

help:
	@echo "make preflight    Check that .env / snmp.yaml / config.alloy are ready"
	@echo "make detect-net   Append HOST_NET=<your-default-interface> to .env"
	@echo "make up           Run preflight, then docker compose up -d"
	@echo "make down         docker compose down"
	@echo "make logs         Tail logs from all containers"

preflight:
	@./scripts/preflight.sh

detect-net:
	@test -f .env || { echo "ERROR: .env doesn't exist yet. Run: cp .env.sample .env" >&2; exit 1; }
	@grep -v '^HOST_NET=' .env > .env.tmp && mv .env.tmp .env
	@echo "HOST_NET=$$(ip -4 route show default | awk '/^default/ {print $$5; exit}')" >> .env
	@echo "set HOST_NET in .env"

up: preflight
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f
