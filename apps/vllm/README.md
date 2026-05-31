# vLLM

Production-grade LLM inference engine. PagedAttention + continuous
batching let one GPU serve many concurrent requests; OpenAI-
compatible `/v1/chat/completions` API drops in for any client that
already talks to OpenAI.

## GPU requirement

vLLM is **GPU-only**. Install only on a cluster with at least one
GPU outpost (NVIDIA driver + container toolkit) and the
`gpu-device-plugin` builtin bundle applied. Without those, the
release deploys but pods stay `Pending` for `nvidia.com/gpu: 1`.

See `outpost/docs/cluster-gpu.md` in the dhnt umbrella for host-side
setup.

## After install

```
$ kubectl get pods -n user-<hash>
vllm-a3b7e-0   1/1   Running   0   3m   (warm-up downloads the model — may take minutes)

$ kubectl port-forward -n user-<hash> svc/vllm-<suffix> 8000:8000
$ curl localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0",
         "messages":[{"role":"user","content":"Hi!"}]}'
```

The default model (`TinyLlama-1.1B`) fits in any consumer GPU. To
serve a bigger model, override at install time:

```
values:
  model:
    repo: meta-llama/Llama-3.1-8B-Instruct
  resources:
    limits:
      nvidia.com/gpu: 1
      memory: 32Gi
```

## Resource defaults

- GPU: 1 (required)
- CPU: 4 cores limit, 1 request
- Memory: 16 GiB limit, 4 request
- Model storage: 20 GiB ephemeral (re-downloaded on Pod restart)

## Tested performance

| Workload | Metric | Result |
|---|---|---|
| TinyLlama-1.1B, batch=1, T4 GPU | tokens / sec @ stream | _not yet measured_ |
| TinyLlama-1.1B, ctx 2048, concurrent=8 | p95 first-token latency | _not yet measured_ |
| idle pod | GPU memory floor | _not yet measured_ |

Numbers populate after a maintainer publishes
`test/stats.json` against a reference GPU node. vLLM perf is
**deeply** GPU-dependent — a T4 and an A100 are an order of
magnitude apart. Re-run the bench on your own GPU to know what
you'll see.

## Reproducing these numbers

Tests require a cluster with a GPU node (NVIDIA driver + container
toolkit + `gpu-device-plugin` builtin). Without GPU, `e2e.sh` exits
non-zero with a clear message.

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/vllm/test
export KUBECONFIG=...                # GPU-capable cluster
./e2e.sh                             # smoke
# perf.sh — coming next iteration; will drive openai-compatible
# /v1/chat/completions and emit stats.json
```

## License

Apache 2.0 — https://github.com/vllm-project/vllm/blob/main/LICENSE
