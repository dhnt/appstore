#!/usr/bin/env bash
# End-to-end smoke test for the librechat app entry.
#
# LibreChat needs at least one LLM provider configured to actually
# chat. This smoke test verifies the deployment is healthy without
# a provider — it confirms:
#   - librechat + bundled mongodb pods reach Ready
#   - /api/health responds 200
#   - the login page renders
# It does NOT verify end-to-end chat flow (that requires a real
# provider; see ../README.md for provider wiring).
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/librechat/test
#   export KUBECONFIG=...
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-librechat-e2e-$$}"
RELEASE="${TEST_RELEASE:-librechat-e2e}"
CHART_REPO="https://danny-avila.github.io/helm-charts"
CHART_VERSION="0.4.0"   # MUST match apps/librechat/app.yaml
PORT="${TEST_PORT:-13080}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

kubectl create ns "$NS"
helm repo add librechat "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update librechat >/dev/null
helm install "$RELEASE" "librechat/librechat" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 10m

kubectl wait pod -n "$NS" -l app.kubernetes.io/name=librechat \
  --for=condition=Ready --timeout=300s

# MongoDB subchart may carry its own labels; just wait on all pods.
kubectl wait pod -n "$NS" --all --for=condition=Ready --timeout=300s

kubectl port-forward -n "$NS" "svc/$RELEASE" "$PORT:3080" >/dev/null &
PF_PID=$!
sleep 3

echo "==> GET /api/health"
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null

echo "==> GET / (login page)"
body=$(curl -fsS "http://127.0.0.1:$PORT/")
echo "$body" | grep -qi 'librechat\|<html' || {
  echo "FAIL — login page response missing expected markup" >&2
  exit 3
}

echo "PASS — librechat e2e smoke complete"
