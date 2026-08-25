#!/usr/bin/env bash
# Catch the common setup mistakes before the stack starts:
#   - .env / config.alloy / compose-base.yaml haven't been copied from .sample
#   - stale copies: Alloy bind-mount still /opt/Grafana/..., River single quotes
#   - .env still contains the placeholder Grafana Cloud values / mixed-stack OTLP
#   - more than one groups/*.env (generate/up start all of them)
#   - empty KTRANS_HOST (raw compose can crash Alloy)
#   - the generator hasn't been run (no compose-groups.generated.yaml, no rendered config/)
#   - docker / envsubst / yq aren't installed or reachable
# State files (state/devices-<group>.yaml) are only warned about — `make up`
# auto-seeds empty stubs for missing ones via the bootstrap target.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

# Git on Windows (and some zip extracts) drop the executable bit. Make already
# invokes scripts with `bash scripts/…`, but cron / `./scripts/foo.sh` still
# need +x. Restore it in bulk on every preflight so operators never chmod one
# file at a time.
chmod a+x scripts/*.sh 2>/dev/null || true

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
for f in .env config.alloy compose-base.yaml; do
  if [[ -f "${f}" ]]; then
    _ok "${f} exists"
  else
    _fail "${f} is missing — run: cp ${f}.sample ${f}"
  fi
done

# --- Stale sample copies (paths/syntax from older clones) ---
if [[ -f compose-base.yaml ]]; then
  if grep -qE '/opt/Grafana' compose-base.yaml; then
    _fail "compose-base.yaml still bind-mounts /opt/Grafana/... (a lab-specific path). Alloy will not see ./config.alloy. Re-copy: cp compose-base.yaml.sample compose-base.yaml"
  elif grep -qE 'source:[[:space:]]*\./config\.alloy' compose-base.yaml; then
    _ok "compose-base.yaml mounts ./config.alloy"
  else
    _warn "compose-base.yaml Alloy volume is not ./config.alloy — check the alloy: volumes: block"
  fi
fi
if [[ -f config.alloy ]]; then
  if grep -qE "'delete_matching_keys" config.alloy; then
    _fail "config.alloy has a single-quoted delete_matching_keys line Alloy rejects. Re-copy: cp config.alloy.sample config.alloy"
  else
    _ok "config.alloy River quotes look valid"
  fi
fi

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
  url="$(grep -E '^GC_OTLP_URL=' .env | tail -n1 | cut -d= -f2- | tr -d '\r')"
  acct="$(grep -E '^GC_OTLP_ACCOUNT=' .env | tail -n1 | cut -d= -f2- | tr -d '\r')"
  if [[ "${url}" == *"otlp-gateway"* && "${url}" == */otlp ]]; then
    _ok "GC_OTLP_URL looks like a Grafana Cloud OTLP gateway (same stack as ACCOUNT + KEY)"
  elif [[ "${url}" != https://foo/otlp ]]; then
    _warn "GC_OTLP_URL should look like https://otlp-gateway-prod-<region>.grafana.net/otlp — all three GC_OTLP_* values must come from the same stack"
  fi
  if [[ "${acct}" =~ ^[0-9]+$ ]]; then
    _ok "GC_OTLP_ACCOUNT is numeric (OTLP instance id, not a Grafana username)"
  elif [[ "${acct}" != "0000000" && -n "${acct}" ]]; then
    _warn "GC_OTLP_ACCOUNT is usually a number from the OpenTelemetry connection snippet"
  fi
fi

# --- Host identity that tags all telemetry and suffixes service.name ---
if [[ -f scripts/host-id.sh ]]; then
  HOST_ID="$(bash scripts/host-id.sh 2>/dev/null)"
  if [[ -n "${HOST_ID}" ]]; then
    if grep -qE '^KTRANS_HOST=.+' .env 2>/dev/null; then
      _ok "deployment.host = ${HOST_ID} (explicit KTRANS_HOST in .env)"
    else
      _ok "deployment.host = ${HOST_ID} (auto from hostname; set KTRANS_HOST in .env to override)"
    fi
  else
    _fail "could not resolve KTRANS_HOST (empty hostname). Set KTRANS_HOST= in .env to a short name — blank plus raw docker compose can crash Alloy"
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
  if [[ ${#GROUP_FILES[@]} -gt 1 ]]; then
    has_discover=0
    for env_file in "${GROUP_FILES[@]}"; do
      role=$(awk -F= '/^ROLE=/{print $2; exit}' "${env_file}")
      if [[ "${role}" == "discover" ]]; then has_discover=1; break; fi
    done
    if [[ "${has_discover}" -eq 1 ]]; then
      _ok "${#GROUP_FILES[@]} groups include a ROLE=discover estate scan (vendor-split layout)"
    else
      _warn "${#GROUP_FILES[@]} groups — make generate / make up start ALL of them. GROUP= only applies to make discover. Start with one *.env until data lands."
    fi
  fi
  if [[ -f groups/onboarding.env && -f groups/single.env ]]; then
    _warn "both groups/onboarding.env and groups/single.env exist — two SNMP pollers. Remove one if you only meant to onboard a single device."
  fi
fi

# --- Generator outputs exist ---
if [[ -f compose-groups.generated.yaml ]]; then
  _ok "compose-groups.generated.yaml exists"
else
  _fail "compose-groups.generated.yaml is missing — run: make generate"
fi
if [[ -f compose-catalog.generated.yaml ]]; then
  _ok "compose-catalog.generated.yaml exists"
else
  _fail "compose-catalog.generated.yaml is missing — run: make generate"
fi
if [[ -f config/catalog.yaml ]]; then
  _ok "config/catalog.yaml exists"
else
  _fail "config/catalog.yaml is missing — run: make generate"
fi

# --- Per-group rendered configs ---
for env_file in "${GROUP_FILES[@]}"; do
  group=$(awk -F= '/^GROUP=/{print $2; exit}' "${env_file}")
  [[ -z "${group}" ]] && continue
  role=$(awk -F= '/^ROLE=/{print $2; exit}' "${env_file}")
  role="${role:-both}"

  if [[ "${role}" != "poll" ]]; then
    if [[ -f "config/discovery-${group}.yaml" ]]; then
      _ok "config/discovery-${group}.yaml exists"
    else
      _fail "config/discovery-${group}.yaml is missing — run: make generate"
    fi
  fi
  if [[ "${role}" != "discover" ]]; then
    if [[ -f "config/poller-${group}.yaml" ]]; then
      _ok "config/poller-${group}.yaml exists"
    else
      _fail "config/poller-${group}.yaml is missing — run: make generate"
    fi
  fi
  if [[ ! -f "state/devices-${group}.yaml" ]]; then
    _warn "state/devices-${group}.yaml is missing — bootstrap will seed an empty stub; run discovery to populate"
  fi
done

# --- NetBox creds required when any group uses DISCOVERY_SOURCE=netbox ---
NETBOX_GROUPS=0
for env_file in "${GROUP_FILES[@]}"; do
  src=$(awk -F= '/^DISCOVERY_SOURCE=/{print $2; exit}' "${env_file}")
  [[ "${src}" == "netbox" ]] && NETBOX_GROUPS=$((NETBOX_GROUPS+1))
done
if [[ "${NETBOX_GROUPS}" -gt 0 ]]; then
  if [[ -f .env ]] && grep -qE '^NETBOX_HOST=.+' .env && grep -qE '^NETBOX_TOKEN=.+' .env; then
    _ok "${NETBOX_GROUPS} netbox group(s); NETBOX_HOST/NETBOX_TOKEN set in .env"
  else
    _fail "${NETBOX_GROUPS} group(s) use DISCOVERY_SOURCE=netbox but NETBOX_HOST/NETBOX_TOKEN are not both set in .env"
  fi
fi

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
