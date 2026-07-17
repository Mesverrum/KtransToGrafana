#!/usr/bin/env bash
# Resolve the per-host identifier used for deployment.host (stamped by Alloy)
# and the service.name host-suffix on every container.
#
# Precedence:
#   1. An explicit, non-blank KTRANS_HOST in .env  -> used verbatim.
#   2. Otherwise                                   -> this machine's hostname.
#
# Shared by the Makefile and scripts/run-discovery.sh so `make up` and the
# discovery cron job always agree on the same value. Prints the resolved value
# on stdout and nothing else.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

v="$(grep -E '^KTRANS_HOST=' "${REPO_ROOT}/.env" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r')"
if [ -n "${v}" ]; then
  printf '%s\n' "${v}"
else
  hostname -s 2>/dev/null || hostname
fi
