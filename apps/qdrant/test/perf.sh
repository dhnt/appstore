#!/usr/bin/env bash
# Performance benchmark for the qdrant app entry.
#
# Inserts N random vectors into a fresh collection, runs M queries,
# emits ./stats.json with insert throughput + query p50/p95/p99 +
# peak memory observed via `kubectl top` (if metrics-server present).
#
# Env knobs:
#   PERF_N_VECTORS   how many vectors to insert         (default 100000)
#   PERF_N_QUERIES   how many queries to time           (default 1000)
#   PERF_DIM         vector dimension                    (default 384)
#   PERF_BATCH       upsert batch size                   (default 1000)
#   TEST_NAMESPACE   override namespace                  (default qdrant-perf-$$)
#
# Outputs:
#   ./stats.json     overwritten each run; commit to publish
#
# Requirements: kubectl, helm, curl, jq, python3.
# Optional: metrics-server (for peak_mem_mib). Without it that field is null.
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/qdrant/test
#   export KUBECONFIG=...
#   ./perf.sh
#   cat stats.json

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
N_VECTORS="${PERF_N_VECTORS:-100000}"
N_QUERIES="${PERF_N_QUERIES:-1000}"
DIM="${PERF_DIM:-384}"
BATCH="${PERF_BATCH:-1000}"
NS="${TEST_NAMESPACE:-qdrant-perf-$$}"
RELEASE="qdrant-perf"
CHART_REPO="https://qdrant.github.io/qdrant-helm"
CHART_VERSION="1.13.0"
PORT="${TEST_PORT:-16334}"

PF_PID=""
cleanup() {
  set +e
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null
  helm uninstall -n "$NS" "$RELEASE" --wait --timeout 2m >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> Bench config: N=$N_VECTORS Q=$N_QUERIES dim=$DIM batch=$BATCH"

kubectl create ns "$NS"
helm repo add qdrant "$CHART_REPO" >/dev/null 2>&1 || true
helm repo update qdrant >/dev/null
helm install "$RELEASE" "qdrant/qdrant" \
  --version "$CHART_VERSION" \
  --namespace "$NS" \
  --values "$HERE/../values.yaml" \
  --wait --timeout 5m
kubectl wait pod -n "$NS" -l app.kubernetes.io/name=qdrant \
  --for=condition=Ready --timeout=120s

kubectl port-forward -n "$NS" "svc/$RELEASE" "$PORT:6333" >/dev/null &
PF_PID=$!
sleep 3
BASE="http://127.0.0.1:$PORT"

curl -fsS -X PUT "$BASE/collections/bench" \
  -H 'Content-Type: application/json' \
  -d "{\"vectors\":{\"size\":$DIM,\"distance\":\"Cosine\"}}" | jq -e '.status == "ok"' >/dev/null

echo "==> Inserting $N_VECTORS vectors in batches of $BATCH"
python3 - "$BASE" "$N_VECTORS" "$DIM" "$BATCH" "$N_QUERIES" "$HERE/stats.json" <<'PY'
import json, os, random, sys, time, urllib.request

base, n, dim, batch, nq, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
random.seed(42)

def post(path, body):
    req = urllib.request.Request(f"{base}{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type":"application/json"}, method="PUT")
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

def search(body):
    req = urllib.request.Request(f"{base}/collections/bench/points/search",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type":"application/json"}, method="POST")
    return json.loads(urllib.request.urlopen(req, timeout=30).read())

t0 = time.time()
for start in range(0, n, batch):
    pts = []
    for i in range(start, min(start+batch, n)):
        pts.append({"id": i+1, "vector": [random.random() for _ in range(dim)]})
    post(f"/collections/bench/points?wait=true", {"points": pts})
insert_secs = time.time() - t0
insert_rps = round(n / insert_secs, 1)

latencies = []
for _ in range(nq):
    q = [random.random() for _ in range(dim)]
    t = time.time()
    search({"vector": q, "limit": 10, "with_payload": False})
    latencies.append((time.time() - t) * 1000.0)

latencies.sort()
def pct(p): return round(latencies[int(len(latencies)*p)-1], 2)

# Peak memory via kubectl top (best-effort; metrics-server may be absent).
import subprocess
try:
    out_top = subprocess.run(["kubectl","top","pod","-n",os.environ.get("NS",""),
                              "--no-headers"], capture_output=True, text=True, timeout=10)
    peak_mem = None
    for line in out_top.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2].endswith("Mi"):
            v = int(parts[2][:-2])
            peak_mem = max(peak_mem or 0, v)
except Exception:
    peak_mem = None

import datetime
def sh(c): return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
node_info = sh("kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'")
node_cap = sh("kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}/{.items[0].status.capacity.memory}'")
commit = sh("git -C "+os.path.dirname(out)+" rev-parse HEAD")

stats = {
    "app": "qdrant",
    "chart": f"qdrant/qdrant-{os.environ.get('CHART_VERSION','1.13.0')}",
    "test_commit": commit,
    "date": datetime.datetime.utcnow().strftime("%Y-%m-%d"),
    "cluster": {"kubelet": node_info, "node_capacity": node_cap},
    "config": {"n_vectors": n, "n_queries": nq, "dim": dim, "batch": batch},
    "results": {
        "insert_throughput_vectors_per_sec": insert_rps,
        "insert_total_secs": round(insert_secs, 1),
        "query_p50_ms": pct(0.50),
        "query_p95_ms": pct(0.95),
        "query_p99_ms": pct(0.99),
        "peak_mem_mib": peak_mem,
    },
}
with open(out, "w") as f:
    json.dump(stats, f, indent=2)
print(json.dumps(stats, indent=2))
PY

echo "==> Stats written to $HERE/stats.json"
