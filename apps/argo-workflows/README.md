# Argo Workflows

Container-native workflow engine for Kubernetes — a DAG of steps, each a pod,
with automatic retry and node-failure rescheduling.

- **Upstream:** https://github.com/argoproj/argo-workflows (CNCF)
- **License:** Apache-2.0 (OSI-approved — meets the appstore curation policy)
- **Chart:** `argo-workflows` from https://argoproj.github.io/argo-helm, pinned in
  `app.yaml` (currently `1.0.20` → argo `v4.0.7`)

## Why it's in the catalog

It is the **tier-5 (DKS) executor for `bashy dag`**. The `dag -> Argo` emitter
(`bashy/scripts/dag-to-argo.sh`) lowers a chunked workflow — e.g. the POSIX/bash
conformance run — into an Argo `Workflow`:

- each chunk becomes a fanned-out pod (`withSequence`);
- the k8s scheduler places pods on whatever nodes are up and **reschedules them
  off a dead/drained node** — so the "dynamic hosts" problem the ssh fleet fights
  by hand disappears;
- `retryStrategy: { retryPolicy: OnError }` retries **system/infrastructure**
  failures (pod evicted, node lost, OOM-kill) but **not** a container's non-zero
  test result — the "retry infra, keep results" contract, native to Argo.

See `dhnt/docs/bashpp-dag-tiered-orchestration.md` (the compiler seam).

## Install

Namespaced by default (`singleNamespace: true`) — no cluster-scoped RBAC. Access
the server through the cloudbox/outpost reverse proxy, not raw. Submit workflows
with `argo submit` or `kubectl create -f <workflow.yaml>` into the app namespace.
