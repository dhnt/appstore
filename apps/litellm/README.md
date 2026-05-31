# LiteLLM

OpenAI-compatible proxy gateway in front of 100+ LLM providers.
Run it once; point all your apps at it; let LiteLLM handle
multi-provider routing, fallbacks, rate-limits, cost caps, and
unified audit logs.

## After install

```
$ kubectl get pods -n user-<hash>
litellm-a3b7e-...   1/1   Running   0   1m
```

In-cluster endpoint (drop-in for any OpenAI client):

```
host: litellm-<release-suffix>.user-<hash>.svc.cluster.local
port: 4000
base_url: http://litellm-<suffix>...:4000
api_key: <your masterkey>
```

## Configuring providers

LiteLLM needs at least one model wired up. Override
`proxy_config.model_list` at install time. Common patterns:

```yaml
proxy_config:
  model_list:
    # Pool from cloudbox outpost Ollama
    - model_name: llama3
      litellm_params:
        model: openai/llama3
        api_base: https://ai.dhnt.io/v1
        api_key: os.environ/CLOUDBOX_TOKEN
    # In-cluster vLLM
    - model_name: tinyllama
      litellm_params:
        model: openai/TinyLlama/TinyLlama-1.1B-Chat-v1.0
        api_base: http://vllm-<suffix>.user-<hash>.svc:8000/v1
        api_key: not-needed
    # OpenAI passthrough
    - model_name: gpt-4o
      litellm_params:
        model: gpt-4o
        api_key: os.environ/OPENAI_API_KEY
```

## Resource defaults

- LiteLLM proxy: 1 CPU / 512 MiB
- Postgres (disabled by default): re-enable via `db.enabled: true`
  if you want budget enforcement + audit log persistence

## Tested performance

| Workload | Metric | Result |
|---|---|---|
| passthrough vs direct (1 req) | proxy overhead | _not yet measured_ |
| 100 req/s mixed providers | p95 added latency | _not yet measured_ |
| 1 replica concurrency ceiling | concurrent reqs before queue | _not yet measured_ |

LiteLLM's hot path is stateless and CPU-bound — measured numbers
will live in `test/stats.json`. Add `db.enabled: true` and the
budget/audit path becomes Postgres-bound (deferred to a separate
test track).

## Reproducing these numbers

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/litellm/test
export KUBECONFIG=...
./e2e.sh
```

`e2e.sh` verifies install + `/health/liveliness`. The smoke test
does NOT round-trip a chat completion (that requires a configured
upstream provider key).

## License

MIT — https://github.com/BerriAI/litellm/blob/main/LICENSE
