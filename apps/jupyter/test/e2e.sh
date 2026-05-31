#!/usr/bin/env bash
# End-to-end smoke test for the jupyter app entry.
#
# Builds on postgres canary by adding multi-pod orchestration
# (hub + proxy + db sqlite-pvc) and HTTP-routing surface coverage.
# Does NOT spawn a singleuser pod — that requires login state and is
# out of scope for a deployment smoke.
#
# Steps:
#   1. helm install jupyterhub/jupyterhub pinned to ../app.yaml
#   2. wait hub + proxy pods Ready
#   3. port-forward proxy-public
#   4. GET / → expect HTTP 200 (login redirect or login page)
#   5. helm uninstall + delete namespace
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/jupyter/test
#   export KUBECONFIG=~/.kube/config
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-jupyter-e2e-$$}"
RELEASE="${TEST_RELEASE:-jupyter-e2e}"
CHART_REPO="https://jupyterhub.github.io/helm-chart/"
CHART_VERSION="3.3.7"   # MUST match apps/jupyter/app.yaml
PORT="${TEST_PORT:-18888}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

kubectl create ns "$NS"
helm repo add jupyterhub "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update jupyterhub >/dev/null

echo "==> helm install $RELEASE (jupyterhub/jupyterhub-$CHART_VERSION)"
helm install "$RELEASE" "jupyterhub/jupyterhub" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 10m

echo "==> Waiting for all pods Ready"
kubectl wait pod -n "$NS" --all --for=condition=Ready --timeout=600s

echo "==> Port-forwarding proxy-public"
kubectl port-forward -n "$NS" svc/proxy-public "$PORT:80" >/dev/null &
PF_PID=$!
sleep 5

echo "==> GET / via proxy-public"
status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")
# Acceptable: 200 (login form) or 302 (redirect to /hub/login)
if [[ "$status" != "200" && "$status" != "302" ]]; then
  echo "FAIL — expected 200 or 302 from proxy-public, got: $status" >&2
  exit 4
fi

echo "PASS — jupyter e2e smoke complete (proxy responded $status)"
