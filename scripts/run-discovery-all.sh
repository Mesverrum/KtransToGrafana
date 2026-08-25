#!/usr/bin/env bash
# Run SNMP discovery for every credential group, then reload ktranslate receivers
# once if any group's device list changed.
#
# Usage: ./scripts/run-discovery-all.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGED=0
FAILED=0

shopt -s nullglob
GROUP_FILES=("${REPO_ROOT}/groups"/*.env)
shopt -u nullglob

if [[ ${#GROUP_FILES[@]} -eq 0 ]]; then
  echo "no groups/*.env files found" >&2
  exit 1
fi

for env_file in "${GROUP_FILES[@]}"; do
  group="$(awk -F= '/^GROUP=/{print $2; exit}' "${env_file}")"
  [[ -z "${group}" ]] && continue
  role="$(awk -F= '/^ROLE=/{print $2; exit}' "${env_file}")"
  role="${role:-both}"
  if [[ "${role}" == "poll" ]]; then
    echo "==> skipping ${group} (ROLE=poll; filled by vendor split)"
    continue
  fi
  echo "==> discovering group: ${group}"
  set +e
  SKIP_RELOAD=1 bash "${REPO_ROOT}/scripts/run-discovery.sh" "${group}"
  rc=$?
  set -e
  case "${rc}" in
    0) CHANGED=1 ;;
    2) ;; # device list unchanged for this group
    *) FAILED=1; echo "discovery failed for ${group} (exit ${rc})" >&2 ;;
  esac
done

if [[ "${FAILED}" -eq 1 ]]; then
  exit 1
fi

if [[ "${CHANGED}" -eq 1 ]]; then
  bash "${REPO_ROOT}/scripts/reload-ktranslate-devices.sh"
else
  echo "all group device lists unchanged; skipping ktranslate reload"
fi
