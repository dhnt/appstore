# LangFuse

Open-source LLM observability — capture every prompt, response,
cost, and latency from your agents/chains, browse them in a Web UI,
and run prompt evals. The bundled chart deploys the OSS feature
set; the cloud/enterprise tier is not packaged here.

## After install

```
$ kubectl get pods -n user-<hash>
langfuse-a3b7e-...    1/1   Running   0   2m
langfuse-a3b7e-postgresql-0   1/1   Running   0   2m   (bundled)
```

Reach via cloudbox's service proxy:

```
https://ai.dhnt.io/cluster/svc/user-<hash>/langfuse-<suffix>:3000/
```

## First-time setup

1. Open the URL above; create an account (admin of your own instance).
2. Create a project; copy the public + secret API keys.
3. Wire the SDK in your app:

```python
from langfuse import Langfuse
client = Langfuse(
    public_key="pk-lf-...",
    secret_key="sk-lf-...",
    host="https://ai.dhnt.io/cluster/svc/user-<hash>/langfuse-<suffix>:3000",
)
```

Or, for in-cluster apps, use the internal DNS name directly:
`http://langfuse-<suffix>.user-<hash>.svc.cluster.local:3000`.

## Resource defaults

- LangFuse app: 1 CPU / 1 GiB
- PostgreSQL sidecar: bundled subchart, 10 GiB PVC, 1 CPU / 1 GiB
- Total quota footprint: ~2 CPU / 2 GiB / 10 GiB storage

## Tested performance

| Workload | Metric | Result |
|---|---|---|
| install → pod Ready | install time | _not yet measured_ |
| 1k traces / minute steady | trace ingest p95 | _not yet measured_ |
| 1M traces accumulated | postgres footprint | _not yet measured_ |

Trace ingest is **postgres-bound** — for high-volume workloads
(>10k traces/min), point at a managed Postgres rather than the
bundled subchart.

## Reproducing these numbers

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/langfuse/test
export KUBECONFIG=...
./e2e.sh
```

`perf.sh` is deferred — measuring trace ingest requires bootstrapping
an org + project + API key first, which can't be done from outside
the UI in v2. We'll add a programmatic-bootstrap perf script once
the langfuse setup API stabilizes.

## License

MIT (OSS core) — https://github.com/langfuse/langfuse/blob/main/LICENSE
