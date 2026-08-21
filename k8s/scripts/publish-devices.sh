#!/bin/sh
# Publish discovery output to /state/devices-<group>.yaml without wiping a
# good list on an empty scan. Mirrors scripts/run-discovery.sh on the host.
#
# Usage: publish-devices.sh <group>
# Expects yq (mikefarah) on PATH and the runtime file at
#   /state/discovery-<group>.runtime.yaml
# which ktranslate mutated in the preceding init container.

set -eu

GROUP="${1:?usage: publish-devices.sh <group>}"
RUNTIME="/state/discovery-${GROUP}.runtime.yaml"
OUT="/state/devices-${GROUP}.yaml"
PREV="/state/devices-${GROUP}.yaml.prev"

if [ ! -f "$RUNTIME" ]; then
  echo "publish-devices: missing ${RUNTIME}" >&2
  exit 1
fi

count="$(yq '.devices | length' "$RUNTIME" 2>/dev/null || echo 0)"
if [ "$count" = "0" ] || [ "$count" = "null" ]; then
  echo "publish-devices: discovery returned 0 devices for ${GROUP}; keeping previous list" >&2
  exit 0
fi

if [ -f "$OUT" ]; then
  cp -f "$OUT" "$PREV"
fi

tmp="${OUT}.tmp.$$"
yq '.devices' "$RUNTIME" > "$tmp"
mv "$tmp" "$OUT"
echo "publish-devices: published ${count} ${GROUP} devices to ${OUT}"

# Flow/syslog watch this flag (catalog @-includes every group). Pollers watch
# their own devices-<group>.yaml. Touching the flag after a successful publish
# is how we ask those receivers to restart without kubectl exec.
date -u +%Y-%m-%dT%H:%M:%SZ > /state/devices-changed.flag

if [ -f "$PREV" ] && cmp -s "$PREV" "$OUT"; then
  echo "publish-devices: device list unchanged for ${GROUP}"
fi
