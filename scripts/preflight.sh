#!/usr/bin/env bash
# Catch the common setup mistakes before the stack starts:
#   - .env / config.alloy haven't been copied from .sample
#   - .env still contains the placeholder Grafana Cloud or NetBox values
#   - the generator hasn't been run (no compose-groups.generated.yaml, no rendered config/)
#   - docker / envsubst / yq aren't installed or reachable
# State files (state/devices-<group>.yaml) are only warned about — `make up`
# auto-seeds empty stubs for missing ones via the bootstrap target.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0
FAIL=0
WARN=0

_ok()   { printf "[ OK ]  %s\n" "$1"; PASS=$((PASS+1)); }
_fail() { printf "[FAIL]  %s\n" "$1"; FAIL=$((FAIL+1)); }
_warn() { printf "[WARN]  %s\n" "$1"; WARN=$((WARN+1)); }

# --- Tooling ---
if docker info >/dev/null 2>&1; then
  _ok "docker daemon is reachable"
else
  _fail "docker daemon is not reachable (is docker running, and is your user in the docker group?)"
fi
if command -v envsubst >/dev/null 2>&1; then
  _ok "envsubst is installed"
else
  _fail "envsubst is missing — install with: sudo apt install gettext-base"
fi
if command -v yq >/dev/null 2>&1; then
  _ok "yq is installed"
else
  _fail "yq is missing — install with: sudo apt install yq"
fi

# --- Base runtime files copied from .sample ---
for f in .env config.alloy; do
  if [[ -f "${f}" ]]; then
    _ok "${f} exists"
  else
    _fail "${f} is missing — run: cp ${f}.sample ${f}"
  fi
done

# --- .env doesn't still have the shipped placeholders ---
if [[ -f .env ]]; then
  if grep -qE '^GC_OTLP_URL=https://foo' .env; then
    _fail ".env GC_OTLP_URL is still the placeholder (https://foo/otlp)"
  else
    _ok ".env GC_OTLP_URL has been customized"
  fi
  if grep -qE '^GC_OTLP_ACCOUNT=0+$' .env; then
    _fail ".env GC_OTLP_ACCOUNT is still the placeholder (all zeros)"
  else
    _ok ".env GC_OTLP_ACCOUNT has been customized"
  fi
  if grep -qE '^GC_OTLP_KEY=glc_foo$' .env; then
    _fail ".env GC_OTLP_KEY is still the placeholder (glc_foo)"
  else
    _ok ".env GC_OTLP_KEY has been customized"
  fi

  # NetBox-specific: token must be replaced, host must look like a URL
  if grep -qE '^NETBOX_TOKEN=replace_me' .env; then
    _fail ".env NETBOX_TOKEN is still the placeholder (replace_me_netbox_api_token)"
  elif ! grep -qE '^NETBOX_TOKEN=.+' .env; then
    _fail ".env NETBOX_TOKEN is empty or missing"
  else
    _ok ".env NETBOX_TOKEN has been customized"
  fi
  if grep -qE '^NETBOX_HOST=https://netbox\.example\.com' .env; then
    _fail ".env NETBOX_HOST is still the placeholder (https://netbox.example.com)"
  elif ! grep -qE '^NETBOX_HOST=https?://' .env; then
    _fail ".env NETBOX_HOST is empty or doesn't look like a URL"
  else
    _ok ".env NETBOX_HOST has been customized"
  fi
fi

# --- At least one group defined ---
shopt -s nullglob
GROUP_FILES=(groups/*.env)
shopt -u nullglob
if [[ ${#GROUP_FILES[@]} -eq 0 ]]; then
  _fail "no group files in groups/*.env — copy groups/<name>.env.sample to groups/<name>.env"
else
  _ok "found ${#GROUP_FILES[@]} group file(s) in groups/"
fi

# --- Generator outputs exist ---
if [[ -f compose-groups.generated.yaml ]]; then
  _ok "compose-groups.generated.yaml exists"
else
  _fail "compose-groups.generated.yaml is missing — run: make generate"
fi

# --- Per-group rendered configs ---
for env_file in "${GROUP_FILES[@]}"; do
  group=$(awk -F= '/^GROUP=/{print $2; exit}' "${env_file}")
  [[ -z "${group}" ]] && continue

  if [[ -f "config/discovery-${group}.yaml" ]]; then
    _ok "config/discovery-${group}.yaml exists"
  else
    _fail "config/discovery-${group}.yaml is missing — run: make generate"
  fi
  if [[ -f "config/poller-${group}.yaml" ]]; then
    _ok "config/poller-${group}.yaml exists"
  else
    _fail "config/poller-${group}.yaml is missing — run: make generate"
  fi
  if [[ ! -f "state/devices-${group}.yaml" ]]; then
    _warn "state/devices-${group}.yaml is missing — bootstrap will seed an empty stub; run discovery to populate"
  fi
done

# --- Ownership sanity on dirs that containers write to ---
for dir in config state; do
  if [[ -d "${dir}" ]]; then
    owner_uid=$(stat -c %u "${dir}" 2>/dev/null || stat -f %u "${dir}" 2>/dev/null || echo "?")
    if [[ "${owner_uid}" != "1000" ]] && [[ "${owner_uid}" != "?" ]]; then
      _warn "${dir}/ is owned by uid ${owner_uid}; containers run as 1000 (sudo chown -R 1000:1000 config/ state/)"
    fi
  fi
done

echo
printf "%d passed, %d failed, %d warnings\n" "${PASS}" "${FAIL}" "${WARN}"
[[ "${FAIL}" -eq 0 ]]
