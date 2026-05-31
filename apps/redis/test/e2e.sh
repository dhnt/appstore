#!/usr/bin/env bash
# End-to-end smoke test for the redis app entry — the
# install-pipeline canary for the whole catalog. If this passes,
# the helm-pull + PVC bind + service + secret-mount chain works on
# your cluster. If it fails, fix that before testing other apps.
#
# Steps:
#   1. helm install bitnami/redis pinned to ../app.yaml's chart
#   2. wait master pod Ready
#   3. fetch the auto-generated password from the Secret
#   4. kubectl exec → redis-cli PING → expect PONG
#   5. SET / GET a key for good measure
#   6. helm uninstall + delete namespace
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/redis/test
#   export KUBECONFIG=~/.kube/config
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-redis-e2e-$$}"
RELEASE="${TEST_RELEASE:-redis-e2e}"
CHART_REPO="https://charts.bitnami.com/bitnami"
CHART_VERSION="20.0.5"   # MUST match apps/redis/app.yaml

cleanup() {
  set +e
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> Creating namespace $NS"
kubectl create ns "$NS"

echo "==> Adding bitnami helm repo"
helm repo add bitnami "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update bitnami >/dev/null

echo "==> helm install $RELEASE (bitnami/redis-$CHART_VERSION)"
helm install "$RELEASE" "bitnami/redis" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 5m

echo "==> Waiting for redis master pod Ready"
kubectl wait pod -n "$NS" -l app.kubernetes.io/component=master \
  --for=condition=Ready --timeout=180s

echo "==> Fetching auto-generated password"
PASS=$(kubectl get secret -n "$NS" "$RELEASE" \
  -o jsonpath='{.data.redis-password}' | base64 -d)
if [[ -z "$PASS" ]]; then
  echo "FAIL — could not read redis-password from secret/$RELEASE" >&2
  exit 3
fi

POD="$RELEASE-master-0"

echo "==> redis-cli PING"
out=$(kubectl exec -n "$NS" "$POD" -- \
  sh -c "REDISCLI_AUTH='$PASS' redis-cli PING")
[[ "$out" == "PONG" ]] || { echo "FAIL — expected PONG, got: $out" >&2; exit 4; }

echo "==> redis-cli SET / GET roundtrip"
kubectl exec -n "$NS" "$POD" -- \
  sh -c "REDISCLI_AUTH='$PASS' redis-cli SET smoke:hello world" >/dev/null
val=$(kubectl exec -n "$NS" "$POD" -- \
  sh -c "REDISCLI_AUTH='$PASS' redis-cli GET smoke:hello")
[[ "$val" == "world" ]] || { echo "FAIL — expected 'world', got: $val" >&2; exit 5; }

echo "PASS — redis e2e smoke complete"
