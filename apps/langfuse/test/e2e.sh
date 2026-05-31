#!/usr/bin/env bash
# End-to-end smoke test for the langfuse app entry.
#
# Verifies install + bundled postgres comes up + the public health
# endpoint responds. End-to-end trace flow requires bootstrapping an
# API key via the UI, which is not scripted here.
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/langfuse/test
#   export KUBECONFIG=...
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-langfuse-e2e-$$}"
RELEASE="${TEST_RELEASE:-langfuse-e2e}"
CHART_REPO="https://langfuse.github.io/langfuse-k8s"
CHART_VERSION="0.13.0"   # MUST match apps/langfuse/app.yaml
PORT="${TEST_PORT:-13000}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

kubectl create ns "$NS"
helm repo add langfuse "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update langfuse >/dev/null
helm install "$RELEASE" "langfuse/langfuse" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 10m

kubectl wait pod -n "$NS" --all --for=condition=Ready --timeout=600s

kubectl port-forward -n "$NS" "svc/$RELEASE" "$PORT:3000" >/dev/null &
PF_PID=$!
sleep 5

echo "==> GET /api/public/health"
curl -fsS "http://127.0.0.1:$PORT/api/public/health" >/dev/null

echo "PASS — langfuse e2e smoke complete"
