#!/bin/sh
# Watch a devices.yaml (or hosts file) on the shared PVC and signal ktranslate.
#
# Used as a sidecar with shareProcessNamespace: true so we can reach the
# ktranslate process in the sibling container. Do not run this on the host.
#
# Usage: state-watch.sh <file> <usr2|term>
#   usr2 — SNMP pollers (ktranslate reloads the @-included device list)
#   term — flow/syslog (needs a full process restart to re-read the catalog)
#
# Why a sidecar instead of kubectl exec: the discovery Job must not need
# RBAC to reach running collectors. The PVC is the contract; this loop is
# the reload.

set -eu

FILE="${1:?usage: state-watch.sh <file> <usr2|term>}"
MODE="${2:?usage: state-watch.sh <file> <usr2|term>}"

sum() {
  cksum "$FILE" 2>/dev/null || echo "missing"
}

signal_ktranslate() {
  # Binary name varies by image tag; try both.
  if [ "$MODE" = "usr2" ]; then
    pkill -USR2 -x ktranslate 2>/dev/null || pkill -USR2 ktranslate 2>/dev/null || true
  else
    pkill -TERM -x ktranslate 2>/dev/null || pkill -TERM ktranslate 2>/dev/null || true
  fi
}

prev="$(sum)"
echo "state-watch: watching ${FILE} mode=${MODE} initial=$(echo "$prev" | awk '{print $1}')"

while true; do
  sleep 10
  cur="$(sum)"
  if [ "$cur" != "$prev" ]; then
    echo "state-watch: ${FILE} changed; signaling ktranslate (${MODE})"
    signal_ktranslate
    prev="$cur"
  fi
done
