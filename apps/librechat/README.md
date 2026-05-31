# LibreChat

Self-hosted ChatGPT-style web UI with **multi-provider** support:
OpenAI, Anthropic, Bedrock, Google, Ollama, vLLM, LiteLLM, any
OpenAI-compatible endpoint. MIT-licensed — fork, rebrand, embed
freely.

A clean alternative to other OSS chat UIs that have non-OSI
preserve-branding licenses.

## After install

```
$ kubectl get pods -n user-<hash>
librechat-a3b7e-0   1/1   Running   0   2m
mongodb-...          1/1   Running   0   2m   (bundled subchart)
```

In-cluster URL:

```
http://librechat-<suffix>.user-<hash>.svc.cluster.local:3080
```

Reach via cloudbox's service proxy:

```
https://ai.dhnt.io/cluster/svc/user-<hash>/librechat-<suffix>:3080/
```

## Wiring to a local LLM

LibreChat needs at least one provider configured. Common patterns:

- **Cloudbox outpost Ollama** (auto-pooled): point at the cloudbox
  LLM gateway at `https://ai.dhnt.io/v1` with your access token.
- **Self-hosted vLLM** (this catalog's `vllm` app): set
  `env.OPENAI_REVERSE_PROXY=http://vllm-<suffix>.user-<hash>.svc:8000/v1`
- **LiteLLM gateway** (this catalog's `litellm` app): set
  `env.OPENAI_REVERSE_PROXY=http://litellm-<suffix>.user-<hash>.svc:4000`
  and use the LiteLLM-issued API key.

Override at install time via the values dialog.

## Resource defaults

- LibreChat: 1 CPU / 1 GiB / 2 GiB PVC
- MongoDB sidecar: bundled subchart, 4 GiB PVC
- Total quota footprint: ~1.5 CPU / 1.5 GiB / 6 GiB storage

## Tested performance

| Workload | Metric | Result |
|---|---|---|
| cold install → pod Ready | install time | _not yet measured_ |
| login page load | TTFB | _not yet measured_ |
| 1 conversation × 100 messages | mongo footprint | _not yet measured_ |

End-to-end chat latency is **upstream-provider bound** — LibreChat
is a thin UI; its perf characteristic is the perf characteristic of
whatever you wire `OPENAI_REVERSE_PROXY` at. Pick your provider's
benchmark, don't blame LibreChat.

## Reproducing these numbers

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/librechat/test
export KUBECONFIG=...
./e2e.sh
```

`e2e.sh` verifies install + login page + `/api/health` without a
provider configured. End-to-end chat flow requires `OPENAI_API_KEY`
or `OPENAI_REVERSE_PROXY` set in `values.yaml` — re-run with your
provider to validate the full path.

## License

MIT — https://github.com/danny-avila/LibreChat/blob/main/LICENSE
