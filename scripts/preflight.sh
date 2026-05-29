#!/usr/bin/env bash
# Catch the three most common setup mistakes before the stack starts:
#   - .env / snmp.yaml / config.alloy haven't been copied from .sample
#   - .env still contains the placeholder Grafana Cloud values
#   - the docker daemon isn't reachable
# Exits non-zero on any hard failure so `make up` (or CI) can gate on it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

PASS=0
FAIL=0
WARN=0

_ok()   { printf "[ OK ]  %s\n"     "$1"; PASS=$((PASS+1)); }
_fail() { printf "[FAIL]  %s\n"     "$1"; FAIL=$((FAIL+1)); }
_warn() { printf "[WARN]  %s\n"     "$1"; WARN=$((WARN+1)); }

# --- docker reachable ---
if docker info >/dev/null 2>&1; then
  _ok "docker daemon is reachable"
else
  _fail "docker daemon is not reachable (is docker running, and is your user in the docker group?)"
fi

# --- runtime files exist ---
for f in .env snmp.yaml config.alloy; do
  if [[ -f "${f}" ]]; then
    _ok "${f} exists"
  else
    _fail "${f} is missing — run: cp ${f}.sample ${f}"
  fi
done

# --- .env doesn't have placeholder values ---
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
  if grep -qE '^HOST_NET=ens4$' .env && ! ip -4 link show ens4 >/dev/null 2>&1; then
    _warn "HOST_NET=ens4 (default) but ens4 doesn't exist on this host — run the detect-net command"
  fi
fi

# --- snmp.yaml has been touched at all (file exists is required above) ---
if [[ -f snmp.yaml ]] && [[ ! -s snmp.yaml ]]; then
  _fail "snmp.yaml exists but is empty"
fi

# --- chown sanity ---
if [[ -f snmp.yaml ]]; then
  owner_uid=$(stat -c %u snmp.yaml 2>/dev/null || stat -f %u snmp.yaml 2>/dev/null || echo "?")
  if [[ "${owner_uid}" != "1000" ]]; then
    _warn "snmp.yaml is owned by uid ${owner_uid}; ktranslate runs as 1000 and may not be able to write during discovery (sudo chown 1000:1000 snmp.yaml)"
  fi
fi

echo
printf "%d passed, %d failed, %d warnings\n" "${PASS}" "${FAIL}" "${WARN}"
[[ "${FAIL}" -eq 0 ]]
