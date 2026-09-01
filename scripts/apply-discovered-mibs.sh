#!/bin/sh
# Union each device's discovered_mibs into poller global.mibs_enabled.
#
# Prefer python3 (host; works when `yq` is kislyuk/jq). Fall back to mikefarah
# yq v4 (k8s init image mikefarah/yq:4 has no python).
#
# Usage:
#   apply-discovered-mibs.sh <poller.yaml> <devices.yaml> [out.yaml]
#
# Exit: 0 unchanged, 1 error, 2 skipped, 3 updated.

set -eu

POLLER="${1:?usage: apply-discovered-mibs.sh <poller.yaml> <devices.yaml> [out.yaml]}"
DEVICES="${2:?}"
OUT="${3:-$POLLER}"

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if command -v python3 >/dev/null 2>&1 && [ -f "${HERE}/apply-discovered-mibs.py" ]; then
  python3 "${HERE}/apply-discovered-mibs.py" "$POLLER" "$DEVICES" "$OUT"
  exit $?
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "apply-discovered-mibs: need python3+PyYAML or mikefarah yq" >&2
  exit 1
fi
# kislyuk yq wraps jq and has no load(); refuse it.
if ! yq --version 2>&1 | grep -qi 'mikefarah'; then
  echo "apply-discovered-mibs: yq is not mikefarah/yq; install python3-yaml or mikefarah yq" >&2
  exit 1
fi

if [ ! -f "$POLLER" ]; then
  echo "apply-discovered-mibs: missing $POLLER" >&2
  exit 1
fi

if [ ! -f "$DEVICES" ]; then
  if [ "$OUT" != "$POLLER" ]; then
    cp "$POLLER" "$OUT"
  fi
  echo "apply-discovered-mibs: no devices file yet ($DEVICES); seed mibs_enabled only"
  exit 2
fi

export POLLER DEVICES
tmp="${OUT}.mibs.tmp.$$"
if ! yq -n '
  load(strenv(POLLER)) as $p
  | (
      load(strenv(DEVICES))
      | (if type == "!!map" and has("devices") then .devices else . end)
      | [ .[] | select(. != null) | .discovered_mibs[]? ]
      | unique
      | sort
    ) as $found
  | $p
  | .global.mibs_enabled = ((.global.mibs_enabled // []) + $found | unique | sort)
' > "$tmp"; then
  rm -f "$tmp"
  echo "apply-discovered-mibs: yq failed" >&2
  exit 1
fi

if [ -f "$OUT" ] && cmp -s "$OUT" "$tmp"; then
  rm -f "$tmp"
  echo "apply-discovered-mibs: mibs_enabled unchanged ($(yq '.global.mibs_enabled | join(", ")' "$OUT"))"
  exit 0
fi

mv "$tmp" "$OUT"
echo "apply-discovered-mibs: mibs_enabled updated: $(yq '.global.mibs_enabled | join(", ")' "$OUT")"
exit 3
