#!/usr/bin/env bash
# End-to-end smoke test for the qdrant app entry.
#
# Steps:
#   1. helm install qdrant from the chart pinned in ../app.yaml
#   2. wait for pod Ready
#   3. port-forward the HTTP API
#   4. create a collection, upsert 3 vectors, run an ANN query
#   5. helm uninstall + delete namespace
#
# Requirements:
#   kubectl, helm, curl, jq, and a KUBECONFIG pointing at any cluster
#   where you have helm-install rights. Tested against k3s (DKS) and
#   kind 0.23+.
#
# Exit code: 0 = pass, non-zero = failure (cleanup still runs).
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/qdrant/test
#   export KUBECONFIG=~/.kube/config   # any cluster you can install into
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-qdrant-e2e-$$}"
RELEASE="${TEST_RELEASE:-qdrant-e2e}"
CHART_REPO="https://qdrant.github.io/qdrant-helm"
CHART_NAME="qdrant"
CHART_VERSION="1.13.0"   # MUST match apps/qdrant/app.yaml spec.chart.version
PORT="${TEST_PORT:-16333}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> Creating namespace $NS"
kubectl create ns "$NS"

echo "==> Adding qdrant helm repo"
helm repo add qdrant "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update qdrant >/dev/null

echo "==> helm install $RELEASE ($CHART_NAME-$CHART_VERSION)"
helm install "$RELEASE" "qdrant/$CHART_NAME" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 5m

echo "==> Waiting for qdrant pod Ready"
kubectl wait pod -n "$NS" -l app.kubernetes.io/name=qdrant \
  --for=condition=Ready --timeout=120s

echo "==> Port-forwarding $PORT → svc/$RELEASE:6333"
kubectl port-forward -n "$NS" "svc/$RELEASE" "$PORT:6333" >/dev/null &
PF_PID=$!
sleep 3
BASE="http://127.0.0.1:$PORT"

echo "==> Creating collection 'smoke' (dim=4, cosine)"
curl -fsS -X PUT "$BASE/collections/smoke" \
  -H 'Content-Type: application/json' \
  -d '{"vectors":{"size":4,"distance":"Cosine"}}' | jq -e '.status == "ok"' >/dev/null

echo "==> Upserting 3 points"
curl -fsS -X PUT "$BASE/collections/smoke/points?wait=true" \
  -H 'Content-Type: application/json' \
  -d '{"points":[
    {"id":1,"vector":[0.10,0.20,0.30,0.40],"payload":{"tag":"a"}},
    {"id":2,"vector":[0.90,0.10,0.10,0.10],"payload":{"tag":"b"}},
    {"id":3,"vector":[0.10,0.90,0.10,0.10],"payload":{"tag":"c"}}
  ]}' | jq -e '.status == "ok"' >/dev/null

echo "==> Searching nearest neighbor of [0.1,0.2,0.3,0.4]"
result=$(curl -fsS -X POST "$BASE/collections/smoke/points/search" \
  -H 'Content-Type: application/json' \
  -d '{"vector":[0.10,0.20,0.30,0.40],"limit":1,"with_payload":true}')
echo "$result" | jq -e '.result[0].id == 1' >/dev/null

echo "PASS — qdrant e2e smoke complete"
