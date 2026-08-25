#!/usr/bin/env bash
# One-shot in-cluster discovery for one credential group.
# Creates a Job from the generated CronJob (same containers as the schedule).
#
# Usage: ./scripts/k8s-discover.sh <group>
#    or: make k8s-discover GROUP=onboarding

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROUP="${1:-}"

if [[ -z "${GROUP}" ]]; then
  echo "usage: $0 <group>   (e.g. onboarding)" >&2
  exit 2
fi

if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

NS="${K8S_NAMESPACE:-ktrans}"
CRON="discover-${GROUP}"
JOB="discover-${GROUP}-manual-$(date +%s)"

if ! kubectl -n "${NS}" get cronjob "${CRON}" >/dev/null 2>&1; then
  echo "ERROR: CronJob ${NS}/${CRON} not found. Run: make k8s-up" >&2
  exit 1
fi

kubectl -n "${NS}" create job --from="cronjob/${CRON}" "${JOB}"
echo "started job/${JOB} in ${NS}"
echo "logs: kubectl -n ${NS} logs job/${JOB} -c discover -f"
echo "      kubectl -n ${NS} logs job/${JOB} -c publish"
echo
echo "wait: kubectl -n ${NS} wait --for=condition=complete job/${JOB} --timeout=15m"
