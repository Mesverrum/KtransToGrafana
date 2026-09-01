#!/usr/bin/env bash
# Run a one-shot SNMP discovery for one credential group and publish the
# discovered device list to state/devices-${group}.yaml for the polling
# container to read via its @-include.
#
# Usage: bash scripts/run-discovery.sh <group>
#
# Exit codes (when SKIP_RELOAD=1): 0 = device list changed, 2 = unchanged, 1 = error.
#
# Intended to be invoked from host cron, e.g.:
#   0 */6 * * * cd /path/to/KtransToGrafana && bash scripts/run-discovery.sh onboarding >> /var/log/ktrans-discovery.log 2>&1
#
# Requires: docker, docker compose, yq (https://github.com/mikefarah/yq).

set -euo pipefail

GROUP="${1:-}"
if [[ -z "${GROUP}" ]]; then
  echo "usage: $0 <group>   (e.g. onboarding)" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve the host identifier the same way `make up` does, so the discovery
# container's service.name carries the host suffix even when this runs from cron
# (where the Makefile's export isn't in scope).
export KTRANS_HOST="$(bash "${REPO_ROOT}/scripts/host-id.sh")"

SRC="${REPO_ROOT}/config/discovery-${GROUP}.yaml"
RUNTIME="${REPO_ROOT}/state/discovery-${GROUP}.runtime.yaml"
DEVICES_OUT="${REPO_ROOT}/state/devices-${GROUP}.yaml"
DEVICES_PREV="${REPO_ROOT}/state/devices-${GROUP}.yaml.prev"

if [[ ! -f "${SRC}" ]]; then
  echo "missing canonical discovery config: ${SRC}" >&2
  exit 1
fi

mkdir -p "${REPO_ROOT}/state"

# Seed the runtime config from the git-tracked canonical config every run.
# This intentionally discards any in-place edits ktranslate made last time
# to the runtime file — git is source of truth for everything except the
# discovered device list.
cp "${SRC}" "${RUNTIME}"
chown 1000:1000 "${RUNTIME}" 2>/dev/null || true

# Snapshot the previous good device list before we touch anything, so a
# discovery failure (empty result, network blip, container crash) can't
# silently wipe the poller's device list.
if [[ -f "${DEVICES_OUT}" ]]; then
  cp "${DEVICES_OUT}" "${DEVICES_PREV}"
fi

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/progress.sh"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/compose-files.sh"
ktrans_compose_files "${REPO_ROOT}"
COMPOSE_ARGS=("${KTRANS_COMPOSE_FILES[@]}")

if [[ ! -f "${REPO_ROOT}/compose-groups.generated.yaml" ]]; then
  echo "missing generated compose file. Run: bash scripts/generate-groups.sh (or make generate)" >&2
  exit 1
fi
if [[ ! -f "${REPO_ROOT}/compose-catalog.generated.yaml" ]]; then
  echo "missing compose-catalog.generated.yaml. Run: bash scripts/generate-groups.sh (or make generate)" >&2
  exit 1
fi

# Run the one-shot discovery container. The compose service is gated by
# the "discovery" profile so it never starts as part of `docker compose up`.
# -T: no TTY so we can capture ktranslate's chatty SNMP logs.
ktrans_step "scanning ${GROUP} (SNMP discovery can take several minutes)"
ktrans_capture "${REPO_ROOT}/state/discovery-${GROUP}.log" \
  docker compose "${COMPOSE_ARGS[@]}" \
    --profile discovery \
    run --rm -T "discover_${GROUP}"
if [[ "${VERBOSE:-0}" != "1" ]]; then
  ktrans_ok "log: state/discovery-${GROUP}.log"
fi

# Extract just the devices block from the post-discovery runtime file.
# If discovery found nothing (or failed in a way that left an empty map),
# roll back to the previous device list rather than publishing the empty one.
DEVICE_COUNT="$(yq '.devices | length' "${RUNTIME}")"
if [[ "${DEVICE_COUNT}" == "0" || "${DEVICE_COUNT}" == "null" ]]; then
  echo "discovery returned 0 devices for ${GROUP}; keeping previous device list" >&2
  exit 1
fi

# Write atomically: emit to a temp file and rename. The poller is reading
# this path; a partial write would be bad.
TMP="${DEVICES_OUT}.tmp.$$"
yq '.devices' "${RUNTIME}" > "${TMP}"
chown 1000:1000 "${TMP}" 2>/dev/null || true
mv "${TMP}" "${DEVICES_OUT}"

echo "published ${DEVICE_COUNT} ${GROUP} devices to ${DEVICES_OUT}"

DEVICES_CHANGED=1
if [[ -f "${DEVICES_PREV}" ]] && cmp -s "${DEVICES_PREV}" "${DEVICES_OUT}"; then
  DEVICES_CHANGED=0
fi

# ROLE=discover: re-split into pollers (dynamic vendors, or config/device-split.yaml).
# ROLE=both (onboarding): leave the mixed poller until the operator runs make split-devices.
ROLE="$(awk -F= '/^ROLE=/{print $2; exit}' "${REPO_ROOT}/groups/${GROUP}.env" 2>/dev/null || true)"
ROLE="${ROLE:-both}"
if [[ "${ROLE}" == "discover" ]]; then
  python3 "${REPO_ROOT}/scripts/split-devices.py" --provision --source-group "${GROUP}" --from "${DEVICES_OUT}"
  bash "${REPO_ROOT}/scripts/generate-groups.sh"
  ktrans_step "starting new pollers after split"
  ktrans_capture "${REPO_ROOT}/state/last-compose-up.log" \
    docker compose "${COMPOSE_ARGS[@]}" up -d --remove-orphans
fi

# Poller global.mibs_enabled is the walk allowlist. Union discovered_mibs from
# every poller device file so vendor tables land without a hand-edit. Do this
# even when the device list is unchanged (upgrade path: same devices, seed IF-MIB).
MIBS_CHANGED=0
shopt -s nullglob
for env_file in "${REPO_ROOT}/groups"/*.env; do
  _group="$(awk -F= '/^GROUP=/{print $2; exit}' "${env_file}")"
  [[ -z "${_group}" ]] && continue
  _role="$(awk -F= '/^ROLE=/{print $2; exit}' "${env_file}")"
  _role="${_role:-both}"
  [[ "${_role}" == "discover" ]] && continue
  _poller="${REPO_ROOT}/config/poller-${_group}.yaml"
  _devices="${REPO_ROOT}/state/devices-${_group}.yaml"
  [[ -f "${_poller}" ]] || continue
  _rc=0
  bash "${REPO_ROOT}/scripts/apply-discovered-mibs.sh" "${_poller}" "${_devices}" || _rc=$?
  case "${_rc}" in
    0|2) ;;
    3) MIBS_CHANGED=1 ;;
    *) exit "${_rc}" ;;
  esac
done
shopt -u nullglob

if [[ "${DEVICES_CHANGED}" -eq 0 && "${MIBS_CHANGED}" -eq 0 ]]; then
  echo "device list and mibs_enabled unchanged for ${GROUP}; skipping ktranslate reload"
  exit 2
fi
if [[ "${DEVICES_CHANGED}" -eq 0 ]]; then
  echo "device list unchanged for ${GROUP}; reloading pollers so new mibs_enabled take effect"
fi

if [[ -n "${SKIP_RELOAD:-}" ]]; then
  echo "device list changed for ${GROUP}; reload deferred (SKIP_RELOAD)"
  exit 0
fi

bash "${REPO_ROOT}/scripts/reload-ktranslate-devices.sh"
