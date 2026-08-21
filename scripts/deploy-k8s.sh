#!/usr/bin/env bash
# Apply generated k8s manifests and create secrets from .env.
# Does not print secret values.
#
# Usage: ./scripts/deploy-k8s.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="${REPO_ROOT}/k8s/generated"
ENV_FILE="${REPO_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} missing — cp .env.sample .env and set GC_OTLP_*" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
# shellcheck disable=SC1091
source "${ENV_FILE}"
set +a

NS="${K8S_NAMESPACE:-ktrans}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl not found on PATH" >&2
  exit 1
fi

python3 "${REPO_ROOT}/scripts/generate-k8s.py"

if [[ ! -f "${GEN}/kustomization.yaml" ]]; then
  echo "ERROR: ${GEN}/kustomization.yaml missing after generate" >&2
  exit 1
fi

kubectl get namespace "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

# OTLP secret — never written into generated YAML.
if [[ -z "${GC_OTLP_URL:-}" || -z "${GC_OTLP_ACCOUNT:-}" || -z "${GC_OTLP_KEY:-}" ]]; then
  echo "ERROR: GC_OTLP_URL / GC_OTLP_ACCOUNT / GC_OTLP_KEY must be set in .env" >&2
  exit 1
fi

kubectl -n "${NS}" create secret generic grafana-otlp \
  --from-literal=url="${GC_OTLP_URL}" \
  --from-literal=account="${GC_OTLP_ACCOUNT}" \
  --from-literal=key="${GC_OTLP_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Optional NetBox / AWS keys (empty is fine; refs are optional: true).
kubectl -n "${NS}" create secret generic ktrans-optional \
  --from-literal=NETBOX_HOST="${NETBOX_HOST:-}" \
  --from-literal=NETBOX_TOKEN="${NETBOX_TOKEN:-}" \
  --from-literal=AWS_REGION="${AWS_REGION:-}" \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}" \
  --from-literal=AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Bootstrap Job is not mutable — delete a leftover so apply can recreate it.
kubectl -n "${NS}" delete job ktrans-state-bootstrap --ignore-not-found >/dev/null

kubectl apply -k "${GEN}"

echo
echo "applied namespace=${NS}"
echo "stamp these addresses on network gear (IPs, not DNS names):"
echo
kubectl -n "${NS}" get configmap ktrans-collector-identity -o jsonpath='{.data.stamp_on_gear}{"\n"}'
echo
echo "warnings:"
kubectl -n "${NS}" get configmap ktrans-collector-identity -o jsonpath='{.data.warning}{"\n"}'
echo
echo "next: make k8s-discover GROUP=<name>   (or wait for the CronJob)"
echo "read: k8s/LIMITATIONS.md"
