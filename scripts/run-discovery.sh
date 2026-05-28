#!/usr/bin/env bash
# Run a one-shot SNMP discovery for one credential group and publish the
# discovered device list to state/devices-${group}.yaml for the polling
# container to read via its @-include.
#
# Usage: ./scripts/run-discovery.sh <cisco|palo>
#
# Intended to be invoked from host cron, e.g.:
#   0 */6 * * * cd /opt/Grafana/KtransToGrafana && ./scripts/run-discovery.sh cisco >> /var/log/ktrans-discovery.log 2>&1
#
# Requires: docker, docker compose, yq (https://github.com/mikefarah/yq).

set -euo pipefail

GROUP="${1:-}"
if [[ -z "${GROUP}" ]]; then
  echo "usage: $0 <group>   (e.g. cisco, palo)" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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

COMPOSE_FILE="${REPO_ROOT}/compose-discovery.yaml"

# Run the one-shot discovery container. The compose service is gated by
# the "discovery" profile so it never starts as part of `docker compose up`.
docker compose -f "${COMPOSE_FILE}" \
  --profile discovery \
  run --rm "discover_${GROUP}"

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

# Only reload the poller if the device list actually changed. A cron tick where
# discovery confirms the same set of devices doesn't need to disturb polling.
if [[ -f "${DEVICES_PREV}" ]] && cmp -s "${DEVICES_PREV}" "${DEVICES_OUT}"; then
  echo "device list unchanged for ${GROUP}; skipping poller reload"
  exit 0
fi

# Signal the long-running poller to re-read its config (which @-includes the
# devices file we just published). docker compose kill resolves the container
# name for us, so we don't have to know the project prefix.
#
# Fail soft: if the poller isn't running (first bootstrap, operator paused it,
# host just rebooted) we don't want to fail the whole discovery run.
POLLER_SERVICE="ktranslate_snmp_${GROUP}"
if docker compose -f "${COMPOSE_FILE}" ps --status running --services 2>/dev/null \
     | grep -qx "${POLLER_SERVICE}"; then
  docker compose -f "${COMPOSE_FILE}" kill -s HUP "${POLLER_SERVICE}"
  echo "sent SIGHUP to ${POLLER_SERVICE}"
else
  echo "poller ${POLLER_SERVICE} not running; new devices will be picked up on next start" >&2
fi
