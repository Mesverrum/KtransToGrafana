.PHONY: up down logs preflight generate bootstrap discover help

COMPOSE := docker compose -f compose-base.yaml -f compose-groups.generated.yaml

help:
	@echo "make preflight              Check that .env / groups / generated configs are ready"
	@echo "make generate               Render configs and compose-groups.generated.yaml from groups/*.env"
	@echo "make bootstrap              Seed empty state/devices-<group>.yaml stubs so pollers can start"
	@echo "make up                     Run preflight + bootstrap, then docker compose up -d"
	@echo "make down                   docker compose down"
	@echo "make logs                   Tail logs from all containers"
	@echo "make discover GROUP=cisco   Run a one-shot discovery for one group"

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

up: preflight bootstrap
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

discover:
	@test -n "$(GROUP)" || { echo "ERROR: pass GROUP=<name>, e.g. make discover GROUP=cisco" >&2; exit 1; }
	@./scripts/run-discovery.sh $(GROUP)
