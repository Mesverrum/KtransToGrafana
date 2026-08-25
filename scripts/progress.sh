#!/usr/bin/env bash
# Step banners + captured logs for make up / discover.
# Work stays in the foreground (so a failure still stops the recipe).
# VERBOSE=1 prints the full command output instead of capturing it.
#
# Usage:
#   source scripts/progress.sh
#   ktrans_step "starting collectors"
#   ktrans_capture state/last-compose-up.log docker compose ... up -d
#   ktrans_ok "deployment.host = site-a"

ktrans_step() { printf '==> %s\n' "$*"; }
ktrans_ok()   { printf '    %s\n' "$*"; }

# Run a command; on failure print the last 40 lines of the log.
ktrans_capture() {
  local log="$1"
  shift
  mkdir -p "$(dirname "${log}")"
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    "$@"
    return
  fi
  if "$@" >"${log}" 2>&1; then
    return 0
  fi
  local rc=$?
  printf '    failed — last 40 lines of %s:\n' "${log}" >&2
  tail -n 40 "${log}" >&2 || true
  return "${rc}"
}
