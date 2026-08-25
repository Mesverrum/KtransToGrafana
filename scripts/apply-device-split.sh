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

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/progress.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/compose-files.sh"
ktrans_compose_files "${REPO_ROOT}"
ktrans_step "sizing container memory"
ktrans_capture "${REPO_ROOT}/state/last-limits.log" \
  bash "${REPO_ROOT}/scripts/compute-limits.sh" --quiet || true
ktrans_step "starting pollers after split"
ktrans_capture "${REPO_ROOT}/state/last-compose-up.log" \
  docker compose "${KTRANS_COMPOSE_FILES[@]}" up -d --remove-orphans

bash "${REPO_ROOT}/scripts/reload-ktranslate-devices.sh"
