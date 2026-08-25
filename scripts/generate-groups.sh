#!/usr/bin/env bash
# Generate per-group ktranslate configs and a Compose service fragment from
# the declarative files in groups/*.env. Every groups/*.env is rendered —
# there is no GROUP= filter (that flag is only for make discover). Copy only
# the group files you intend to run. ROLE=discover emits only the discovery
# service; ROLE=poll emits only the poller; default (both) emits both.
# Run this:
#   - once during initial setup
#   - whenever you add, remove, or modify a group
# Then bring the stack up:
#   docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml up -d
#
# Requires: bash, envsubst (apt install gettext-base on Ubuntu).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROUPS_DIR="${REPO_ROOT}/groups"
TEMPLATES_DIR="${REPO_ROOT}/templates"
CONFIG_DIR="${REPO_ROOT}/config"
STATE_DIR="${REPO_ROOT}/state"
COMPOSE_OUT="${REPO_ROOT}/compose-groups.generated.yaml"
CATALOG_OUT="${CONFIG_DIR}/catalog.yaml"
CATALOG_COMPOSE_OUT="${REPO_ROOT}/compose-catalog.generated.yaml"
# REPO_PATH ends up baked into the bind-mount sources of the rendered
# compose-groups.generated.yaml. Default to REPO_ROOT (where the script
# lives), but let the caller override — needed when this script runs from
# inside a container (e.g. the ktranslate-tools admin sidecar) that has a
# different idea of its own filesystem layout than the docker host does.
REPO_PATH="${REPO_PATH:-${REPO_ROOT}}"
export REPO_PATH

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not found. Install with: sudo apt install gettext-base" >&2
  exit 1
fi

mkdir -p "${CONFIG_DIR}" "${STATE_DIR}"

# Only the placeholders listed here get substituted. Everything else
# (notably docker compose's own ${OTEL_SERVICE_NAME}, ${NF_SOURCE}, ${GC_*})
# stays literal so docker compose can resolve it from .env at runtime.
SUBST_VARS='$GROUP $METALISTEN_PORT $TRAP_PORT $TRAP_COMMUNITY $DISCOVERY_THREADS $POLL_INTERVAL_SEC $CIDRS_YAML $NETBOX_BLOCK_YAML $DEFAULT_COMMUNITIES_YAML $DEFAULT_V3_YAML $OTHER_V3S_YAML $REPO_PATH'

shopt -s nullglob
GROUP_FILES=("${GROUPS_DIR}"/*.env)
shopt -u nullglob
if [[ ${#GROUP_FILES[@]} -eq 0 ]]; then
  echo "ERROR: no group files found in ${GROUPS_DIR}/*.env" >&2
  echo "       Copy groups/<name>.env.sample to groups/<name>.env to define a group." >&2
  exit 1
fi

# ---------- Pre-pass: validate every group file and detect collisions ----------
declare -A USED_ML_PORTS
declare -A USED_TRAP_PORTS
# Ports used by the static services in compose-base.yaml. Any group claiming
# one of these would fail at `docker compose up` time; catch it here instead.
RESERVED_PORTS_TCP="9995 9996 9998 4317 12346"
RESERVED_PORTS_UDP="1514"

for env_file in "${GROUP_FILES[@]}"; do
  (
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a

    ROLE="${ROLE:-both}"
    case "${ROLE}" in
      both|discover|poll) ;;
      *) echo "ERROR: ${env_file}: ROLE must be both, discover, or poll, got '${ROLE}'" >&2; exit 1 ;;
    esac

    # ROLE=discover: scan only (no long-running poller). ROLE=poll: poll only
    # (device list comes from split-devices-by-vendor.py). Default both = today.
    required_vars=(GROUP SNMP_VERSION POLL_INTERVAL_SEC)
    if [[ "${ROLE}" != "poll" ]]; then
      required_vars+=(DISCOVERY_THREADS)
    fi
    if [[ "${ROLE}" != "discover" ]]; then
      required_vars+=(TRAP_COMMUNITY METALISTEN_PORT TRAP_PORT)
    fi
    for var in "${required_vars[@]}"; do
      if [[ -z "${!var:-}" ]]; then
        echo "ERROR: ${env_file}: missing required variable ${var}" >&2
        exit 1
      fi
    done

    # DISCOVERY_SOURCE selects how this group's device list is built.
    if [[ "${ROLE}" == "poll" ]]; then
      DISCOVERY_SOURCE="${DISCOVERY_SOURCE:-split}"
    else
      DISCOVERY_SOURCE="${DISCOVERY_SOURCE:-cidr}"
    fi
    case "${DISCOVERY_SOURCE}" in
      cidr)
        if [[ "${ROLE}" == "poll" ]]; then
          echo "ERROR: ${env_file}: ROLE=poll groups use DISCOVERY_SOURCE=split (not cidr)" >&2
          exit 1
        fi
        if [[ -z "${TARGETS:-}" ]]; then
          echo "ERROR: ${env_file}: DISCOVERY_SOURCE=cidr requires TARGETS" >&2
          exit 1
        fi ;;
      netbox)
        if [[ "${ROLE}" == "poll" ]]; then
          echo "ERROR: ${env_file}: ROLE=poll groups use DISCOVERY_SOURCE=split (not netbox)" >&2
          exit 1
        fi
        if [[ -z "${NETBOX_IP_TO_PICK:-}" ]]; then
          echo "ERROR: ${env_file}: DISCOVERY_SOURCE=netbox requires NETBOX_IP_TO_PICK" >&2
          exit 1
        fi
        # NETBOX_HOST/NETBOX_TOKEN live in .env (they're container-runtime creds,
        # not generator inputs), so preflight validates them — not this script.
        if [[ -z "${NETBOX_TAG:-}${NETBOX_SITE:-}${NETBOX_LOCATION:-}${NETBOX_TENANT:-}${NETBOX_ROLE:-}${NETBOX_STATUS:-}" ]]; then
          echo "WARN:  ${env_file}: no NetBox filters set; this group will pull every device from NetBox" >&2
        fi ;;
      split)
        if [[ "${ROLE}" != "poll" ]]; then
          echo "ERROR: ${env_file}: DISCOVERY_SOURCE=split requires ROLE=poll" >&2
          exit 1
        fi ;;
      *) echo "ERROR: ${env_file}: DISCOVERY_SOURCE must be cidr, netbox, or split, got '${DISCOVERY_SOURCE}'" >&2; exit 1 ;;
    esac

    # Validate a full v3 credential set for a given suffix ("" = primary, "_2"..).
    _check_v3_set() {
      local sfx="$1" v name
      for v in SNMP_V3_USER SNMP_V3_AUTH_PROTOCOL SNMP_V3_AUTH_PASS SNMP_V3_PRIV_PROTOCOL SNMP_V3_PRIV_PASS; do
        name="${v}${sfx}"
        if [[ -z "${!name:-}" ]]; then
          echo "ERROR: ${env_file}: v3 set ${name} is required (a partial v3 credential set)" >&2
          exit 1
        fi
      done
    }

    # Cloud secret reference (aws.sm.NAME / azure.kv.NAME / gcp.sm.NAME) replaces
    # inline SNMP_V3_* fields. See docs/secrets-aws.md.
    _check_v3_secret() {
      local name="$1" val="$2"
      if [[ ! "${val}" =~ ^(aws\.sm\.|azure\.kv\.|gcp\.sm\.)[A-Za-z0-9/_+=.@-]+$ ]]; then
        echo "ERROR: ${env_file}: ${name}='${val}' must look like aws.sm.SecretName (or azure.kv./gcp.sm.)" >&2
        exit 1
      fi
    }

    case "${SNMP_VERSION}" in
      v2c)
        # SNMP_V2_COMMUNITY may be a single value or a comma-separated list of
        # candidate communities for discovery to try.
        if [[ -z "${SNMP_V2_COMMUNITY:-}" ]]; then
          echo "ERROR: ${env_file}: SNMP_VERSION=v2c requires SNMP_V2_COMMUNITY" >&2
          exit 1
        fi ;;
      v3)
        if [[ -n "${SNMP_V3_SECRET:-}" ]]; then
          _check_v3_secret "SNMP_V3_SECRET" "${SNMP_V3_SECRET}"
          if [[ -n "${SNMP_V3_USER:-}" ]]; then
            echo "ERROR: ${env_file}: set either SNMP_V3_SECRET or SNMP_V3_USER/… fields, not both" >&2
            exit 1
          fi
        else
          _check_v3_set ""
        fi ;;
      mixed)
        # An onboarding group: try any/all provided credentials during discovery.
        if [[ -n "${SNMP_V3_SECRET:-}" ]]; then
          echo "ERROR: ${env_file}: SNMP_V3_SECRET is not supported with SNMP_VERSION=mixed (use v3)" >&2
          exit 1
        fi
        if [[ -z "${SNMP_V2_COMMUNITY:-}" && -z "${SNMP_V3_USER:-}" ]]; then
          echo "ERROR: ${env_file}: SNMP_VERSION=mixed requires at least one credential (SNMP_V2_COMMUNITY and/or SNMP_V3_USER)" >&2
          exit 1
        fi
        [[ -n "${SNMP_V3_USER:-}" ]] && _check_v3_set "" ;;
      *) echo "ERROR: ${env_file}: SNMP_VERSION must be v2c, v3, or mixed, got '${SNMP_VERSION}'" >&2; exit 1 ;;
    esac

    # Numbered v3 sets: either complete inline fields or SNMP_V3_SECRET_N.
    if [[ "${SNMP_VERSION}" == "v3" || "${SNMP_VERSION}" == "mixed" ]]; then
      for n in 2 3 4 5 6 7 8 9; do
        _u="SNMP_V3_USER_${n}"
        _s="SNMP_V3_SECRET_${n}"
        if [[ -n "${!_s:-}" ]]; then
          if [[ "${SNMP_VERSION}" != "v3" ]]; then
            echo "ERROR: ${env_file}: ${_s} requires SNMP_VERSION=v3" >&2
            exit 1
          fi
          _check_v3_secret "${_s}" "${!_s}"
          if [[ -n "${!_u:-}" ]]; then
            echo "ERROR: ${env_file}: set either ${_s} or ${_u}/… fields, not both" >&2
            exit 1
          fi
        elif [[ -n "${!_u:-}" ]]; then
          _check_v3_set "_${n}"
        fi
      done
    fi
    true  # the loop above can end on a false test; keep the subshell's exit 0
  )

  GN=$(awk -F= '/^GROUP=/{print $2; exit}'           "${env_file}")
  GR=$(awk -F= '/^ROLE=/{print $2; exit}'            "${env_file}")
  GR="${GR:-both}"
  if [[ "${GR}" == "discover" ]]; then
    continue
  fi
  ML=$(awk -F= '/^METALISTEN_PORT=/{print $2; exit}' "${env_file}")
  TR=$(awk -F= '/^TRAP_PORT=/{print $2; exit}'       "${env_file}")
  if [[ -n "${USED_ML_PORTS[${ML}]:-}" ]]; then
    echo "ERROR: METALISTEN_PORT ${ML} used by both '${USED_ML_PORTS[${ML}]}' and '${GN}'" >&2
    exit 1
  fi
  if [[ -n "${USED_TRAP_PORTS[${TR}]:-}" ]]; then
    echo "ERROR: TRAP_PORT ${TR} used by both '${USED_TRAP_PORTS[${TR}]}' and '${GN}'" >&2
    exit 1
  fi
  for r in ${RESERVED_PORTS_TCP}; do
    if [[ "${ML}" == "${r}" ]]; then
      echo "ERROR: METALISTEN_PORT ${ML} (group ${GN}) collides with a static service" >&2
      exit 1
    fi
  done
  for r in ${RESERVED_PORTS_UDP}; do
    if [[ "${TR}" == "${r}" ]]; then
      echo "ERROR: TRAP_PORT ${TR} (group ${GN}) collides with a static service" >&2
      exit 1
    fi
  done
  USED_ML_PORTS[${ML}]="${GN}"
  USED_TRAP_PORTS[${TR}]="${GN}"
done

# ---------- Render pass ----------
cat > "${COMPOSE_OUT}" <<EOF
# GENERATED by scripts/generate-groups.sh from groups/*.env — do not edit by hand.
# Merge with compose-base.yaml at runtime:
#   docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml up -d
services:
EOF

for env_file in "${GROUP_FILES[@]}"; do
  (
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a

    ROLE="${ROLE:-both}"
    DISCOVERY_THREADS="${DISCOVERY_THREADS:-4}"
    POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-60}"
    export ROLE DISCOVERY_THREADS POLL_INTERVAL_SEC
    # Discovery YAML still has a trap: block; keep it valid YAML when ROLE=discover
    # omits host ports (the discover container does not listen).
    if [[ "${ROLE}" == "discover" ]]; then
      TRAP_PORT="${TRAP_PORT:-0}"
      TRAP_COMMUNITY="${TRAP_COMMUNITY:-public}"
      METALISTEN_PORT="${METALISTEN_PORT:-0}"
      export TRAP_PORT TRAP_COMMUNITY METALISTEN_PORT
    fi
    # Render the discovery-source block. cidr groups fill the `cidrs:` list;
    # netbox groups leave cidrs empty and add a `netbox:` block whose host/token
    # stay as ${NETBOX_HOST}/${NETBOX_TOKEN} literals for ktranslate to resolve
    # from the discover container's env at runtime. Both feed the same two
    # template placeholders (CIDRS_YAML slots after `cidrs:`, NETBOX_BLOCK_YAML
    # slots after `no_use_bulkwalkall:`), so there is only one discovery template.
    # ROLE=poll / DISCOVERY_SOURCE=split skips this — those groups have no
    # discovery YAML.
    if [[ "${ROLE}" == "poll" ]]; then
      DISCOVERY_SOURCE="${DISCOVERY_SOURCE:-split}"
    else
      DISCOVERY_SOURCE="${DISCOVERY_SOURCE:-cidr}"
    fi
    CIDRS_YAML=" []"
    NETBOX_BLOCK_YAML=""
    if [[ "${DISCOVERY_SOURCE}" == "cidr" ]]; then
      CIDRS_YAML=$'\n'
      IFS=',' read -ra TGT_ARR <<< "${TARGETS}"
      for t in "${TGT_ARR[@]}"; do
        t="${t// /}"
        CIDRS_YAML+="      - ${t}"$'\n'
      done
      CIDRS_YAML="${CIDRS_YAML%$'\n'}"
      NETBOX_BLOCK_YAML=""
    elif [[ "${DISCOVERY_SOURCE}" == "netbox" ]]; then
      CIDRS_YAML=" []"
      # Each filter is omitted entirely when empty, so an unused filter doesn't
      # render as `tag: []` (which NetBox reads as "match the empty tag" rather
      # than "no constraint").
      NETBOX_FILTERS_YAML=""
      _append_array_filter() {
        local key="$1" csv="$2"
        [[ -z "${csv}" ]] && return
        NETBOX_FILTERS_YAML+=$'\n        '"${key}"":"
        IFS=',' read -ra _VALS <<< "${csv}"
        for v in "${_VALS[@]}"; do
          NETBOX_FILTERS_YAML+=$'\n          - '"${v// /}"
        done
      }
      _append_scalar_filter() {
        local key="$1" val="$2"
        [[ -z "${val}" ]] && return
        NETBOX_FILTERS_YAML+=$'\n        '"${key}"": ${val}"
      }
      _append_array_filter  tag      "${NETBOX_TAG:-}"
      _append_array_filter  site     "${NETBOX_SITE:-}"
      _append_array_filter  location "${NETBOX_LOCATION:-}"
      _append_array_filter  tenant   "${NETBOX_TENANT:-}"
      _append_scalar_filter role     "${NETBOX_ROLE:-}"
      _append_scalar_filter status   "${NETBOX_STATUS:-}"
      # $'...' is ANSI-C quoting: it does NOT expand ${NETBOX_HOST}/${NETBOX_TOKEN},
      # so those stay literal for ktranslate. The filters and ip_to_pick are
      # spliced in double-quoted, so their actual values land here at generate time.
      NETBOX_BLOCK_YAML=$'\n    netbox:\n        host: ${NETBOX_HOST}\n        token: ${NETBOX_TOKEN}'"${NETBOX_FILTERS_YAML}"$'\n        ip_to_pick: '"${NETBOX_IP_TO_PICK}"
    fi
    export CIDRS_YAML NETBOX_BLOCK_YAML

    # ---- Discovery credentials ----
    # A group may carry MULTIPLE candidate credentials so discovery can match
    # them to devices when the mapping isn't known up front. Discovery tries
    # every one and records the working credential per device; the poller then
    # uses each device's own credential. This renders three placeholders that
    # slot into the discovery config (each at a fixed indent that matters):
    #   default_communities (list)  default_v3 (primary)  other_v3s (the rest)

    # default_communities — the comma-separated SNMP_V2_COMMUNITY, for v2c and
    # mixed groups. Each entry becomes a candidate community discovery tries.
    DEFAULT_COMMUNITIES_YAML=" []"
    if [[ "${SNMP_VERSION}" == "v2c" || "${SNMP_VERSION}" == "mixed" ]] && [[ -n "${SNMP_V2_COMMUNITY:-}" ]]; then
      _comms=""
      IFS=',' read -ra _COMM_ARR <<< "${SNMP_V2_COMMUNITY}"
      for c in "${_COMM_ARR[@]}"; do
        c="${c#"${c%%[![:space:]]*}"}"; c="${c%"${c##*[![:space:]]}"}"   # trim ws
        [[ -z "$c" ]] && continue
        _comms+=$'\n      - '"${c}"
      done
      [[ -n "${_comms}" ]] && DEFAULT_COMMUNITIES_YAML="${_comms}"
    fi

    # Emit the 7 v3 fields. $1 = first-line prefix (8 spaces for default_v3, or
    # "      - " for an other_v3s list item), $2 = continuation indent.
    _v3_block() {
      local first="$1" ind="$2"
      printf '\n%suser_name: %s' "$first" "$3"
      printf '\n%sauthentication_protocol: %s' "$ind" "$4"
      printf '\n%sauthentication_passphrase: %s' "$ind" "$5"
      printf '\n%sprivacy_protocol: %s' "$ind" "$6"
      printf '\n%sprivacy_passphrase: %s' "$ind" "$7"
      printf '\n%scontext_engine_id: ""' "$ind"
      printf '\n%scontext_name: ""' "$ind"
    }

    # default_v3 (primary set) + other_v3s (numbered sets _2.._9), for v3/mixed.
    # SNMP_V3_SECRET=aws.sm.Name renders as a cloud-secret reference (see docs/secrets-aws.md).
    DEFAULT_V3_YAML=" null"
    OTHER_V3S_YAML=""
    if [[ "${SNMP_VERSION}" == "v3" && -n "${SNMP_V3_SECRET:-}" ]]; then
      DEFAULT_V3_YAML=" ${SNMP_V3_SECRET}"
      _others=""
      for n in 2 3 4 5 6 7 8 9; do
        _s="SNMP_V3_SECRET_${n}"
        [[ -z "${!_s:-}" ]] && continue
        _others+=$'\n      - '"${!_s}"
      done
      [[ -n "${_others}" ]] && OTHER_V3S_YAML=$'\n    other_v3s:'"${_others}"
    elif [[ "${SNMP_VERSION}" == "v3" || "${SNMP_VERSION}" == "mixed" ]] && [[ -n "${SNMP_V3_USER:-}" ]]; then
      DEFAULT_V3_YAML="$(_v3_block '        ' '        ' "${SNMP_V3_USER}" "${SNMP_V3_AUTH_PROTOCOL}" "${SNMP_V3_AUTH_PASS}" "${SNMP_V3_PRIV_PROTOCOL}" "${SNMP_V3_PRIV_PASS}")"
      _others=""
      for n in 2 3 4 5 6 7 8 9; do
        _u="SNMP_V3_USER_${n}"; [[ -z "${!_u:-}" ]] && continue
        _ap="SNMP_V3_AUTH_PROTOCOL_${n}"; _apass="SNMP_V3_AUTH_PASS_${n}"
        _pp="SNMP_V3_PRIV_PROTOCOL_${n}"; _ppass="SNMP_V3_PRIV_PASS_${n}"
        _others+="$(_v3_block '      - ' '        ' "${!_u}" "${!_ap}" "${!_apass}" "${!_pp}" "${!_ppass}")"
      done
      [[ -n "${_others}" ]] && OTHER_V3S_YAML=$'\n    other_v3s:'"${_others}"
    fi
    export DEFAULT_COMMUNITIES_YAML DEFAULT_V3_YAML OTHER_V3S_YAML

    _sec_note=""
    [[ -n "${SNMP_V3_SECRET:-}" ]] && _sec_note=" secret=${SNMP_V3_SECRET}"
    if [[ "${ROLE}" != "poll" ]]; then
      envsubst "${SUBST_VARS}" < "${TEMPLATES_DIR}/discovery.yaml.tmpl" \
        > "${CONFIG_DIR}/discovery-${GROUP}.yaml"
      envsubst "${SUBST_VARS}" < "${TEMPLATES_DIR}/compose-discover.yaml.tmpl" \
        >> "${COMPOSE_OUT}"
    fi
    if [[ "${ROLE}" != "discover" ]]; then
      envsubst "${SUBST_VARS}" < "${TEMPLATES_DIR}/poller.yaml.tmpl" \
        > "${CONFIG_DIR}/poller-${GROUP}.yaml"
      envsubst "${SUBST_VARS}" < "${TEMPLATES_DIR}/compose-poller.yaml.tmpl" \
        >> "${COMPOSE_OUT}"
    fi

    echo "  rendered ${GROUP}  (role=${ROLE}  discovery=${DISCOVERY_SOURCE}  snmp=${SNMP_VERSION}${_sec_note}  ports=${METALISTEN_PORT:-none}/${TRAP_PORT:-none})"
  )
done

# ---------- Device catalog for flow / syslog receivers ----------
# Discover-only groups are the raw scan output; pollers (and the catalog)
# consume the split vendor files so flow/syslog do not double-count.
declare -a CATALOG_GROUPS=()
for env_file in "${GROUP_FILES[@]}"; do
  group="$(awk -F= '/^GROUP=/{print $2; exit}' "${env_file}")"
  [[ -z "${group}" ]] && continue
  role="$(awk -F= '/^ROLE=/{print $2; exit}' "${env_file}")"
  role="${role:-both}"
  [[ "${role}" == "discover" ]] && continue
  CATALOG_GROUPS+=("${group}")
done

{
  echo "# GENERATED by scripts/generate-groups.sh — do not edit by hand."
  echo "# Enrichment-only catalog: flow and syslog match device_ip → device_name"
  echo "# and apply global.user_tags without SNMP polling."
  if [[ ${#CATALOG_GROUPS[@]} -eq 0 ]]; then
    echo "devices: {}"
  else
    echo "devices:"
    for group in "${CATALOG_GROUPS[@]}"; do
      echo "  - \"@/state/devices-${group}.yaml\""
    done
  fi
  cat <<'EOF'
global:
  user_tags: {}
EOF
} > "${CATALOG_OUT}"

{
  echo "# GENERATED by scripts/generate-groups.sh — do not edit by hand."
  echo "# Merge with compose-base.yaml at runtime:"
  echo "#   docker compose -f compose-base.yaml -f compose-groups.generated.yaml -f compose-catalog.generated.yaml up -d"
  echo "services:"
  for svc in ktranslate_flow ktranslate_syslog; do
    echo "  ${svc}:"
    echo "    volumes:"
    echo "      - ${REPO_PATH}/config/catalog.yaml:/snmp.yaml:ro"
    for group in "${CATALOG_GROUPS[@]}"; do
      echo "      - ${REPO_PATH}/state/devices-${group}.yaml:/state/devices-${group}.yaml:ro"
    done
  done
} > "${CATALOG_COMPOSE_OUT}"

echo
echo "wrote $(ls "${CONFIG_DIR}"/discovery-*.yaml 2>/dev/null | wc -l) discovery configs, $(ls "${CONFIG_DIR}"/poller-*.yaml 2>/dev/null | wc -l) poller configs, ${CATALOG_OUT}, ${CATALOG_COMPOSE_OUT}, and ${COMPOSE_OUT}"
