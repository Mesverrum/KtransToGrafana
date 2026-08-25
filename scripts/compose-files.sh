#!/usr/bin/env bash
# Docker Compose -f list for this repo.
#
# Always uses tracked compose-base.yaml.sample so git pull updates the pipeline.
# Optional gitignored compose.override.yaml layers on top (ports, networks, Alloy).
#
# Print flags:  bash scripts/compose-files.sh
# Extra overlay: bash scripts/compose-files.sh compose-sflow.yaml
# Bash array:   source scripts/compose-files.sh && ktrans_compose_files "$ROOT"

ktrans_compose_files() {
  local root="$1"
  shift || true
  KTRANS_COMPOSE_FILES=(
    -f "${root}/compose-base.yaml.sample"
  )
  if [[ -f "${root}/compose.override.yaml" ]]; then
    KTRANS_COMPOSE_FILES+=(-f "${root}/compose.override.yaml")
  fi
  KTRANS_COMPOSE_FILES+=(
    -f "${root}/compose-groups.generated.yaml"
    -f "${root}/compose-catalog.generated.yaml"
    -f "${root}/compose-limits.generated.yaml"
  )
  while [[ $# -gt 0 ]]; do
    KTRANS_COMPOSE_FILES+=(-f "${root}/${1}")
    shift
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _root="$(cd "$(dirname "$0")/.." && pwd)"
  ktrans_compose_files "$_root" "$@"
  printf '%s ' "${KTRANS_COMPOSE_FILES[@]}"
  echo
fi
