#!/usr/bin/env bash
# End-to-end smoke test for the vllm app entry.
#
# Requires a cluster with at least one node advertising nvidia.com/gpu.
# Without a GPU node, the pod stays Pending and the script fails with
# a clear message (does NOT silently pass).
#
# Steps:
#   1. helm install vllm from the chart pinned in ../app.yaml
#   2. wait for pod Ready (long timeout — model download is slow)
#   3. port-forward the OpenAI-compatible API
#   4. POST /v1/chat/completions with a 1-token prompt; verify reply
#   5. helm uninstall + delete namespace
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/vllm/test
#   export KUBECONFIG=...    # GPU-capable cluster
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-vllm-e2e-$$}"
RELEASE="${TEST_RELEASE:-vllm-e2e}"
CHART_REPO="https://substratusai.github.io/helm"
CHART_VERSION="0.4.0"   # MUST match apps/vllm/app.yaml
PORT="${TEST_PORT:-18000}"
# Long timeout — first install downloads the model from HF.
INSTALL_TIMEOUT="${TEST_INSTALL_TIMEOUT:-15m}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> Verifying GPU node presence"
gpu_count=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  | grep -cv '^$' || true)
if [[ "$gpu_count" -lt 1 ]]; then
  echo "FAIL — no nodes advertise nvidia.com/gpu. vLLM requires a GPU node." >&2
  exit 2
fi

kubectl create ns "$NS"
helm repo add substratusai "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update substratusai >/dev/null
helm install "$RELEASE" "substratusai/vllm" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout "$INSTALL_TIMEOUT"

kubectl wait pod -n "$NS" -l app.kubernetes.io/name=vllm \
  --for=condition=Ready --timeout="$INSTALL_TIMEOUT"

kubectl port-forward -n "$NS" "svc/$RELEASE" "$PORT:8000" >/dev/null &
PF_PID=$!
sleep 5

echo "==> POST /v1/chat/completions"
resp=$(curl -fsS -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0",
       "messages":[{"role":"user","content":"hi"}],
       "max_tokens":4}')
echo "$resp" | jq -e '.choices[0].message.content | length > 0' >/dev/null

echo "PASS — vllm e2e smoke complete"
