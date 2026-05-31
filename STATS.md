# dhnt/appstore — published performance stats

This file is the catalog-wide index of published `perf.sh` results.
Numbers come from running each app's `test/perf.sh` and committing
the resulting `test/stats.json`.

**Read this section first** — the numbers below are claims with a
reproduction path. They are NOT guarantees. Your cluster's CPU,
memory, storage IOPS, network, and k8s version will shift the
results, sometimes by an order of magnitude.

## How to reproduce any row

Every app in the table has a `test/` folder with `e2e.sh` and
`perf.sh`. The scripts are pure bash + `kubectl` + `helm` +
`curl` + `jq` + `python3` — no cloudbox-specific tooling. Clone
the repo, point `KUBECONFIG` at any cluster you can install into,
and run.

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/<id>/test
export KUBECONFIG=~/.kube/config
./e2e.sh   # smoke
./perf.sh  # benchmark; writes stats.json
```

If your numbers diverge from what's claimed below, open an issue
with your `stats.json` attached. Divergence either means the claim
is stale or your cluster is shaped differently — both are worth
knowing.

## Test cluster (what the published numbers were measured on)

The published stats are measured on a reference DKS cluster.
Per-row test commits + cluster capacity strings are embedded in
each app's `test/stats.json` so you can compare against your own
hardware.

| Field | Value |
|---|---|
| Kubernetes distro | k3s (DKS) |
| Kubelet version | _see per-app `stats.json`_ |
| Node CPU / RAM | _see per-app `stats.json`_ |
| Storage | local-path provisioner (k3s default) |
| GPU | NVIDIA T4 (vLLM only) |

## Published results

| App | Workload | Headline metric | Result | Tested |
|---|---|---|---|---|
| redis    | install → PING/SET/GET smoke   | install pipeline OK | _pending_ | _pending_ |
| postgres | install → CREATE/INSERT/SELECT | install pipeline OK | _pending_ | _pending_ |
| jupyter  | install → proxy-public GET /   | install pipeline OK | _pending_ | _pending_ |
| qdrant   | 100k×384 cosine, top-10        | query p95         | _pending_ | _pending_ |
| vllm     | TinyLlama-1.1B, batch=1, T4    | tokens/sec        | _pending_ | _pending_ |
| librechat | login + 1 conversation         | TTFB              | _pending_ | _pending_ |
| langfuse | 1k traces/min steady           | ingest p95        | _pending_ | _pending_ |
| litellm  | 1 replica, OpenAI passthrough  | proxy overhead    | _pending_ | _pending_ |

The top three (redis, postgres, jupyter) are **install-pipeline
canaries** — their job is to prove the chart-pull + PVC bind +
service path works on a given cluster. Run them in order; if redis
fails, fix the cluster before chasing the rest.

A row reads "_pending_" until the maintainers commit a populated
`test/stats.json` for that app. Contributors are welcome to PR a
populated stats.json for any pending app — see CONTRIBUTING.md.

## Why "starter sizing", not "production sizing"

The defaults in each app's `values.yaml` are deliberately
**conservative** — they keep idle resource cost low so a single
DKS node can host several apps side-by-side. They are NOT tuned
for production-grade throughput. The catalog's job is to get an
app running quickly; tuning is left to the operator, who knows
their workload.

When you click Install in the cloudbox SPA, the values dialog
lets you override any field before submit. The numbers above
tell you what the starter sizing achieves; pick a tier up if your
workload demands more.
