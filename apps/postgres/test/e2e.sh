#!/usr/bin/env bash
# End-to-end smoke test for the postgres app entry.
#
# Builds on the redis canary by adding init-container + secret-mount
# coverage. If redis passes but THIS fails, look at:
#   - PVC mode (RWO vs RWX) — postgres init writes to PVC at start
#   - PG init container output (kubectl logs <pod> -c <init-container>)
#   - secret rotation / postgres-password field name in the secret
#
# Steps:
#   1. helm install bitnami/postgresql pinned to ../app.yaml
#   2. wait primary pod Ready (init container takes 20-40s)
#   3. fetch postgres password from Secret
#   4. kubectl exec → psql → CREATE TABLE + INSERT + SELECT
#   5. helm uninstall + delete namespace
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/postgres/test
#   export KUBECONFIG=~/.kube/config
#   ./e2e.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NS="${TEST_NAMESPACE:-postgres-e2e-$$}"
RELEASE="${TEST_RELEASE:-postgres-e2e}"
CHART_REPO="https://charts.bitnami.com/bitnami"
CHART_VERSION="15.5.31"   # MUST match apps/postgres/app.yaml

cleanup() {
  set +e
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

kubectl create ns "$NS"
helm repo add bitnami "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update bitnami >/dev/null

echo "==> helm install $RELEASE (bitnami/postgresql-$CHART_VERSION)"
helm install "$RELEASE" "bitnami/postgresql" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 10m

echo "==> Waiting for postgres primary pod Ready"
kubectl wait pod -n "$NS" -l app.kubernetes.io/name=postgresql \
  --for=condition=Ready --timeout=300s

echo "==> Fetching auto-generated password"
PASS=$(kubectl get secret -n "$NS" "$RELEASE-postgresql" \
  -o jsonpath='{.data.postgres-password}' | base64 -d)
if [[ -z "$PASS" ]]; then
  echo "FAIL — could not read postgres-password from secret/$RELEASE-postgresql" >&2
  exit 3
fi

POD="$RELEASE-postgresql-0"

echo "==> psql CREATE/INSERT/SELECT roundtrip"
kubectl exec -n "$NS" "$POD" -- \
  sh -c "PGPASSWORD='$PASS' psql -U postgres -d postgres -tA -c \"
    CREATE TABLE smoke (k text PRIMARY KEY, v text);
    INSERT INTO smoke VALUES ('hello', 'world');
  \"" >/dev/null

val=$(kubectl exec -n "$NS" "$POD" -- \
  sh -c "PGPASSWORD='$PASS' psql -U postgres -d postgres -tA -c \"
    SELECT v FROM smoke WHERE k = 'hello';
  \"")
[[ "$val" == "world" ]] || { echo "FAIL — expected 'world', got: $val" >&2; exit 4; }

echo "PASS — postgres e2e smoke complete"
