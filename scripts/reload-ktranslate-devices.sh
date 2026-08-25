#!/usr/bin/env bash
# Reload ktranslate receivers that read state/devices-*.yaml (catalog + pollers).
# Called after any group's device list changes so flow/syslog/traps and all SNMP
# pollers pick up the latest @-included device maps.
#
# Usage: ./scripts/reload-ktranslate-devices.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_ARGS=(
  -f "${REPO_ROOT}/compose-base.yaml"
  -f "${REPO_ROOT}/compose-groups.generated.yaml"
  -f "${REPO_ROOT}/compose-catalog.generated.yaml"
)

if [[ ! -f "${REPO_ROOT}/compose-groups.generated.yaml" ]]; then
  echo "missing compose-groups.generated.yaml — run: make generate" >&2
  exit 1
fi
if [[ ! -f "${REPO_ROOT}/compose-catalog.generated.yaml" ]]; then
  echo "missing compose-catalog.generated.yaml — run: make generate" >&2
  exit 1
fi

RESTART_SERVICES=(ktranslate_flow ktranslate_syslog ktranslate_traps)
RELOAD_POLLERS=()

shopt -s nullglob
for env_file in "${REPO_ROOT}/groups"/*.env; do
  group="$(awk -F= '/^GROUP=/{print $2; exit}' "${env_file}")"
  [[ -z "${group}" ]] && continue
  role="$(awk -F= '/^ROLE=/{print $2; exit}' "${env_file}")"
  role="${role:-both}"
  [[ "${role}" == "discover" ]] && continue
  RELOAD_POLLERS+=("ktranslate_snmp_${group}")
done
shopt -u nullglob

RUNNING_RESTART=()
for svc in "${RESTART_SERVICES[@]}"; do
  if docker compose "${COMPOSE_ARGS[@]}" ps --status running --services 2>/dev/null \
       | grep -qx "${svc}"; then
    RUNNING_RESTART+=("${svc}")
  fi
done

RUNNING_POLLERS=()
for svc in "${RELOAD_POLLERS[@]}"; do
  if docker compose "${COMPOSE_ARGS[@]}" ps --status running --services 2>/dev/null \
       | grep -qx "${svc}"; then
    RUNNING_POLLERS+=("${svc}")
  fi
done

if [[ ${#RUNNING_RESTART[@]} -eq 0 && ${#RUNNING_POLLERS[@]} -eq 0 ]]; then
  echo "no ktranslate catalog/poller services running; reload skipped"
  exit 0
fi

bash "${REPO_ROOT}/scripts/refresh-flow-dns.sh"

if [[ ${#RUNNING_RESTART[@]} -gt 0 ]]; then
  docker compose "${COMPOSE_ARGS[@]}" restart "${RUNNING_RESTART[@]}"
fi

for svc in "${RUNNING_POLLERS[@]}"; do
  docker compose "${COMPOSE_ARGS[@]}" kill -s USR2 "${svc}"
done

echo "reloaded flow/syslog/traps: ${RUNNING_RESTART[*]:-none}; SIGUSR2 pollers: ${RUNNING_POLLERS[*]:-none}"
