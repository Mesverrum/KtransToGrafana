#!/usr/bin/env bash
# Quiet `make up` / `make up-demo`: step banners, Docker chatter in state/*.log.
# Foreground — do not background this. VERBOSE=1 for the old full dump.
#
# Usage: bash scripts/bring-up.sh [--demo]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

DEMO=0
if [[ "${1:-}" == "--demo" ]]; then
  DEMO=1
fi

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/progress.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/compose-files.sh"

export KTRANS_HOST="$(bash "${REPO_ROOT}/scripts/host-id.sh")"

if [[ -n "${GROUP:-}" ]]; then
  echo "NOTE: GROUP=${GROUP} is ignored. make up starts every groups/*.env. GROUP= only applies to make discover." >&2
fi

ktrans_step "checking setup"
if [[ "${VERBOSE:-0}" == "1" ]]; then
  bash "${REPO_ROOT}/scripts/preflight.sh"
else
  bash "${REPO_ROOT}/scripts/preflight.sh" --quiet
fi

ktrans_step "seeding empty device lists"
mkdir -p state dnsmasq
for envfile in groups/*.env; do
  [[ -f "${envfile}" ]] || continue
  group="$(awk -F= '/^GROUP=/{print $2; exit}' "${envfile}")"
  [[ -z "${group}" ]] && continue
  if [[ ! -f "state/devices-${group}.yaml" ]]; then
    echo '{}' > "state/devices-${group}.yaml"
    ktrans_ok "seeded state/devices-${group}.yaml"
  fi
done
[[ -f dnsmasq/hosts.generated.conf ]] || echo '# pending refresh-flow-dns' > dnsmasq/hosts.generated.conf
[[ -f dnsmasq/upstream.conf ]] || echo 'server=host.docker.internal' > dnsmasq/upstream.conf

ktrans_step "refreshing flow DNS"
ktrans_capture "${REPO_ROOT}/state/last-flow-dns.log" \
  bash "${REPO_ROOT}/scripts/refresh-flow-dns.sh" --quiet

ktrans_step "sizing container memory"
ktrans_capture "${REPO_ROOT}/state/last-limits.log" \
  bash "${REPO_ROOT}/scripts/compute-limits.sh" --quiet

ktrans_step "starting collectors (image pulls can take a few minutes the first time)"
if [[ "${DEMO}" -eq 1 ]]; then
  ktrans_compose_files "${REPO_ROOT}" compose-sflow.yaml
else
  ktrans_compose_files "${REPO_ROOT}"
fi
ktrans_capture "${REPO_ROOT}/state/last-compose-up.log" \
  docker compose "${KTRANS_COMPOSE_FILES[@]}" up -d

ktrans_ok "deployment.host = ${KTRANS_HOST}"
ktrans_ok "collectors are up. Next: make discover GROUP=onboarding"
if [[ "${VERBOSE:-0}" != "1" ]]; then
  ktrans_ok "compose log: state/last-compose-up.log"
fi
