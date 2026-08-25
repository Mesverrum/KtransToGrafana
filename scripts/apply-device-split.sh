#!/usr/bin/env bash
# Split a discovery device list, provision missing ROLE=poll groups, regenerate
# compose, and start new pollers. Traps/flow/syslog stay on the catalog listener.
#
# Usage:
#   bash scripts/apply-device-split.sh
#   bash scripts/apply-device-split.sh --source-group onboarding --explain
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

python3 "${REPO_ROOT}/scripts/split-devices.py" --provision --promote-discover "$@"

bash "${REPO_ROOT}/scripts/generate-groups.sh"

mkdir -p "${REPO_ROOT}/state"
shopt -s nullglob
for envfile in "${REPO_ROOT}/groups"/*.env; do
  group="$(awk -F= '/^GROUP=/{print $2; exit}' "${envfile}")"
  [[ -z "${group}" ]] && continue
  if [[ ! -f "${REPO_ROOT}/state/devices-${group}.yaml" ]]; then
    echo '{}' > "${REPO_ROOT}/state/devices-${group}.yaml"
    echo "seeded empty state/devices-${group}.yaml"
  fi
done
shopt -u nullglob

if [[ -f "${REPO_ROOT}/compose-base.yaml" ]]; then
  bash "${REPO_ROOT}/scripts/compute-limits.sh" || true
  compose=(
    docker compose
    -f "${REPO_ROOT}/compose-base.yaml"
    -f "${REPO_ROOT}/compose-groups.generated.yaml"
    -f "${REPO_ROOT}/compose-catalog.generated.yaml"
  )
  if [[ -f "${REPO_ROOT}/compose-limits.generated.yaml" ]]; then
    compose+=(-f "${REPO_ROOT}/compose-limits.generated.yaml")
  fi
  "${compose[@]}" up -d --remove-orphans
fi

bash "${REPO_ROOT}/scripts/reload-ktranslate-devices.sh"
