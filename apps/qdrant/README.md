# Qdrant

Open-source vector similarity search engine — the storage layer for
RAG embeddings, agent memory, and any nearest-neighbor lookup over
high-dimensional vectors. Rust-based; fast; small footprint.

## After install

```
$ kubectl get pods -n user-<hash>
qdrant-a3b7e-qdrant-0   1/1   Running   0   1m
```

In-cluster endpoint:

```
host: qdrant-<release-suffix>.user-<hash>.svc.cluster.local
http: 6333
grpc: 6334
```

Python client:

```python
from qdrant_client import QdrantClient
client = QdrantClient(host="qdrant-...", port=6333)
client.upsert(collection_name="docs", points=[...])
```

## Resource defaults

- Storage: 5 GiB PVC
- CPU: 1 core limit, 100m request
- Memory: 1 GiB limit, 256 MiB request
- Metrics endpoint: off (no Prometheus assumed in user-ns)

## Tested performance

The numbers below come from running `test/perf.sh` against the
chart pinned in `app.yaml` with the defaults in `values.yaml`. Stats
are stored in `test/stats.json` — open that file for the full record
(test commit SHA, cluster spec, date).

| Workload | Metric | Result |
|---|---|---|
| 100k vectors × dim 384, cosine | insert throughput | _not yet measured_ |
| 100k vectors, 1k queries, top-10 | query p50 / p95 / p99 | _not yet measured_ |
| under load | peak pod memory | _not yet measured_ |

Numbers will populate after the first published `perf.sh` run lands
in this catalog. Until then, treat the resource defaults above as
"starter sizing" — override at install time via the cloudbox values
dialog if you push higher cardinality.

## Reproducing these numbers

Tests are pure bash + `kubectl` + `helm` + `curl` + `jq` + `python3`.
No cloudbox-specific tooling — they run against any cluster.

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/qdrant/test
export KUBECONFIG=~/.kube/config         # any cluster you can install into

# Smoke test (~2 min): install → create/insert/search → uninstall
./e2e.sh

# Perf benchmark (~5–15 min depending on N): writes stats.json
PERF_N_VECTORS=100000 PERF_N_QUERIES=1000 PERF_DIM=384 ./perf.sh
cat stats.json
```

If your `stats.json` numbers diverge significantly from what this
README claims, please open an issue against `dhnt/appstore` with
your `stats.json` attached — divergent results either mean the
claim is stale or your cluster is configured differently, and both
are worth knowing.

## License

Apache 2.0 — https://github.com/qdrant/qdrant/blob/master/LICENSE
