#!/bin/sh
# Create empty device-list stubs on the PVC so pollers can start before the
# first discovery run. Same idea as `make bootstrap` on Compose.
#
# Usage: seed-state.sh <group> [<group> ...]

set -eu

if [ "$#" -lt 1 ]; then
  echo "usage: seed-state.sh <group> [<group> ...]" >&2
  exit 1
fi

mkdir -p /state

for group in "$@"; do
  path="/state/devices-${group}.yaml"
  if [ ! -f "$path" ]; then
    echo '{}' > "$path"
    echo "seeded ${path}"
  else
    echo "exists ${path}"
  fi
done
