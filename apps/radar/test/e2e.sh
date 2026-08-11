#!/usr/bin/env bash
set -euo pipefail

chart_version=1.9.2
release=${RELEASE:-radar}
namespace=${NAMESPACE:-radar-smoke}
repo_name=skyhook
repo_url=https://skyhook-io.github.io/helm-charts

cleanup() {
  helm uninstall "$release" --namespace "$namespace" >/dev/null 2>&1 || true
  kubectl delete namespace "$namespace" --ignore-not-found >/dev/null 2>&1 || true
  helm repo remove "$repo_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

helm repo add "$repo_name" "$repo_url" >/dev/null
helm repo update >/dev/null
kubectl create namespace "$namespace" >/dev/null
helm install "$release" "$repo_name/radar" \
  --version "$chart_version" \
  --namespace "$namespace" \
  --values "$HERE/../values.yaml" \
  --set auth.mode=proxy \
  --set basePath=/radar \
  --set mcp.enabled=false \
  --set rbac.helm=false \
  --set rbac.secrets=false \
  --wait --timeout 5m >/dev/null

kubectl rollout status deployment/"$release" --namespace "$namespace" --timeout=5m >/dev/null
kubectl get service "$release" --namespace "$namespace" >/dev/null
kubectl get clusterrole "$release" >/dev/null
kubectl get clusterrolebinding "$release" >/dev/null
echo "radar chart ${chart_version}: install and service smoke passed"
