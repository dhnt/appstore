#!/usr/bin/env bash
# End-to-end smoke test for the litellm app entry.
#
# Verifies install + the proxy's health endpoints respond. Does NOT
# round-trip a chat completion (that requires a configured upstream
# provider key, which the smoke test doesn't have).
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/litellm/test
#   export KUBECONFIG=...
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-litellm-e2e-$$}"
RELEASE="${TEST_RELEASE:-litellm-e2e}"
CHART_REPO="https://berriai.github.io/litellm-helm"
CHART_VERSION="0.2.0"   # MUST match apps/litellm/app.yaml
PORT="${TEST_PORT:-14000}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

kubectl create ns "$NS"
helm repo add litellm "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update litellm >/dev/null
helm install "$RELEASE" "litellm/litellm-helm" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 5m

kubectl wait pod -n "$NS" --all --for=condition=Ready --timeout=300s

kubectl port-forward -n "$NS" "svc/$RELEASE" "$PORT:4000" >/dev/null &
PF_PID=$!
sleep 3

echo "==> GET /health/liveliness"
curl -fsS "http://127.0.0.1:$PORT/health/liveliness" >/dev/null

echo "PASS — litellm e2e smoke complete"
