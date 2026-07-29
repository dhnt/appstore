# Argo Workflows

Container-native workflow engine for Kubernetes — a DAG of steps, each a pod,
with automatic retry and node-failure rescheduling.

- **Upstream:** <https://github.com/argoproj/argo-workflows> (CNCF)
- **Chart:** `argo-workflows` from <https://argoproj.github.io/argo-helm>,
  pinned in `app.yaml` to **`1.0.20`** → Argo Workflows **`4.0.7`**
- **Install scope:** namespaced controller (`singleNamespace: true`) **plus
  cluster-scoped CRDs** — see "Cluster scope, honestly" below

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

`values.yaml` offers that retry contract through
`controller.workflowDefaults`, so a workflow that does not override it gets the
default automatically.

## Cluster scope, honestly

`app.yaml` declares `spec.rbac.clusterScoped: true`. That is deliberate and
should not be "fixed" back to `false`:

- the default install creates the Argo **CRDs**, and a CRD is a cluster-scoped
  object by definition;
- `clusterworkflowtemplates` needs a **ClusterRole** for the controller and
  server to read it.

`singleNamespace: true` confines the controller's *watch* to the install
namespace. That is a tenancy property, not a cluster-scope property. An entry
that ships CRDs while advertising "no cluster scope" would be lying to the
reviewer, so this one accepts the cloudbox-admin gate instead. `test/render.sh`
asserts the declaration matches what the chart actually renders.

### Two install modes

| Mode | `crds.install` | Who can install | Notes |
|---|---|---|---|
| **Default** | `true` | cloudbox-admin (clusterScoped gate) | first install on a cluster; `crds.keep: true` so uninstall never cascade-deletes Workflow objects |
| **CRDs pre-applied** | `false` | any user with namespace rights | an admin applies the CRDs cluster-wide once; subsequent per-user installs create only namespaced objects |

## Placement boundaries

DKS nodes carry `outpost.dhnt.io/backend={k3s,vk-native}` and
`outpost.dhnt.io/runtime={agent,virtual}`, plus the standard `kubernetes.io/os`
and `kubernetes.io/arch`.

The chart's controller and server pods are explicitly pinned to
`outpost.dhnt.io/backend=k3s` with a hard `nodeSelector` and empty
`tolerations`. The checked-in smoke `WorkflowTemplate` independently carries
that same explicit hard selector for every pod it creates. These are concrete
pod-spec constraints, never `preferred…` affinity.

`controller.workflowDefaults` supplies the same k3s selector and empty
tolerations to normal submissions that omit those fields. It is
**defense-in-depth defaulting, not admission enforcement**: a submitted
`Workflow` or `WorkflowTemplate` can override the defaults, including
`nodeSelector` and `tolerations`. This minimal package therefore does not claim
to hard-pin arbitrary or hostile submitted Workflows.

Third-party multi-tenant installs that require enforcement against hostile
submissions must add an external admission policy (for example, a cluster
`ValidatingAdmissionPolicy` or an existing policy engine) that rejects
disallowed workflow placement. No admission controller or policy is bundled
with this package.

The placement matters because vk-native provides *exactly one container,
literal env, and no init containers, sidecars, `envFrom`, projected secrets,
logs or exec*. argoexec's init + wait sidecars need strictly more than that.

Native execution is therefore reached **indirectly** — see the smoke below.

## Workflow archive and artifact repository

Both are **off by default** and both are wired with **Secret references only**.
No credential ever lives in this repo.

```bash
# workflow archive (needs an external PostgreSQL)
kubectl -n <ns> create secret generic argo-archive-postgres \
  --from-literal=username=argo --from-literal=password='<pw>'

# S3-compatible artifact repository (SeaweedFS / MinIO / R2 / S3)
kubectl -n <ns> create secret generic argo-artifacts-s3 \
  --from-literal=accesskey='<id>' --from-literal=secretkey='<key>'
```

Then uncomment the `controller.persistence` and `artifactRepository.s3` blocks
in `values.yaml`. `test/fixtures/enabled.values.yaml` is a ready-made overlay of
exactly that shape, and `test/render.sh` renders it to prove the wiring produces
`accessKeySecret` / `secretKeySecret` / `passwordSecret` references and emits no
`Secret` object of its own.

## vk-native indirection smoke

`smoke/vk-native-indirection.yaml` is a checked-in `WorkflowTemplate` that makes
the DKS contract machine-testable:

```
Smoke's Argo pods -> outpost.dhnt.io/backend=k3s       (hard, no fallback)
The payload pod -> outpost.dhnt.io/backend=vk-native (hard, no fallback)
```

An Argo `resource` template — running on k3s — **creates**, **watches**
(`successCondition` / `failureCondition` against the Job's status) and
**deletes** (`onExit`) an ordinary `batch/v1` Job. That Job's pod is the only
thing that touches a native node, and it stays inside the vk-native envelope:
exactly one container, literal `env` only,
`automountServiceAccountToken: false` (the default SA token is a projected
volume), no init containers, no sidecars, no volumes, no `envFrom`.

**No fallback** is enforced structurally, not by convention:

| Rule | Where | Why |
|---|---|---|
| hard `nodeSelector` on both sides | workflow `spec` + Job pod | the scheduler cannot place the pod elsewhere |
| `tolerations: []` on the workflow | workflow `spec` | nothing readmits vk-native for Argo pods |
| no `affinity` / `preferred…` anywhere | both | a soft rule *is* a fallback |
| `backoffLimit: 0`, `restartPolicy: Never` | Job | no fallback in the time dimension either |
| positive `activeDeadlineSeconds` | Job | a Pending, unschedulable Job reaches terminal failure |
| explicit `failureCondition` | resource template | Argo observes the Job failure; it cannot pass by omission |
| `pods/log`, `pods/exec` not granted | `smoke/rbac.yaml` | granting them would imply a capability vk-native does not have |

`test/static.sh` asserts every row of that table.

### Running it

```bash
kubectl -n <ns> apply -f smoke/rbac.yaml            # namespaced Role + RoleBinding
kubectl -n <ns> apply -f smoke/vk-native-indirection.yaml
argo -n <ns> submit --from workflowtemplate/vk-native-indirection-smoke \
  -p job-image='ghcr.io/example/payload@sha256:<64 hex>' \
  -p job-command='["/bin/true"]' \
  -p target-os=linux -p target-arch=arm64 \
  -p job-active-deadline-seconds=600 --wait
```

`job-image` and `job-command` are **required parameters with no defaults**, on
purpose:

- **digest, not tag.** A mutable tag makes the smoke non-deterministic, so the
  image must be `repo/name@sha256:…`. `test/static.sh` fails if a literal
  tagged image appears in the template.
- **no honest cross-OS default exists.** A native fleet may be
  linux/darwin/windows on amd64/arm64. Pretending a Linux image runs natively
  on a Windows or macOS node would be a lie, so the target `kubernetes.io/os`
  and `kubernetes.io/arch` are explicit parameters and the artifact that runs
  there is yours to supply. This ships as a *template plus a tested structure*,
  not as a turnkey command.

The virtual-kubelet taint key is the `vk-taint-key` parameter (default
`virtual-kubelet.io/provider`); override it if your fleet taints differently.

The Job also has a native scheduler boundary:
`job-active-deadline-seconds` defaults to **300 seconds**. If no matching
vk-native node can schedule the payload, Kubernetes keeps the pod Pending until
this positive deadline expires, marks the Job failed, and the Argo resource
template observes that terminal failure through its existing
`failureCondition`. Override it at submission with
`-p job-active-deadline-seconds=<positive-seconds>` to match fleet scheduling
latency. This is additional to, and does not replace, the workflow/task timeout
semantics enforced by Argo.

## Install

Namespaced by default. Access the server through the cloudbox/outpost reverse
proxy — `server.serviceType` is `ClusterIP` and `server.ingress.enabled` is
`false`. Submit workflows with `argo submit` or
`kubectl create -f <workflow.yaml>` into the app namespace.

## Tests

Both are deterministic and fail closed — a missing prerequisite is a failure,
never a silent skip. Neither touches a cluster.

| Script | Needs | Checks |
|---|---|---|
| `test/static.sh` | `python3` + PyYAML | catalog/schema invariants, chart-pin drift across `app.yaml` / `README.md` / `test/render.sh`, the CRD↔`clusterScoped` honesty rule, no inline credentials, the full vk-native indirection + no-fallback contract |
| `test/render.sh` | `helm` 3.x (or `HELM_BIN=…`), `python3` + PyYAML, network | fetches the exact pinned chart into a temp dir, verifies its sha256 against `test/chart.sha256`, renders twice (defaults, and with archive + S3 enabled), asserts controller / server / RBAC / ConfigMap output |

`test/render.sh` never mutates your Helm config (it points
`HELM_{CACHE,CONFIG,DATA}_HOME` into its temp dir) and removes everything it
wrote on exit, so the repo stays clean. On a host with no `helm` it exits
non-zero with instructions rather than passing vacuously.

The first run needs the chart digest recorded once, from a host you trust:

```bash
ARGO_TRUST_ON_FIRST_USE=1 ./test/render.sh    # prints the sha256; writes nothing
printf '%s\n' '<sha256>' > test/chart.sha256  # commit this
```

## Tested performance

_Not yet measured._ This entry is `featured: false`, so `test/perf.sh` and a
published `stats.json` are not required (see `CONTRIBUTING.md`). The metric that
matters here is fan-out latency — time from `argo submit` to all N chunk pods
Running — and it is dominated by the cluster's scheduler and image cache rather
than by Argo.

## Reproducing these numbers

```bash
git clone https://github.com/dhnt/appstore
cd appstore/apps/argo-workflows
./test/static.sh                 # offline invariants
./test/render.sh                 # pinned-chart render (needs helm or HELM_BIN)
```

## License

Upstream Argo Workflows and the `argo-workflows` Helm chart are
[Apache-2.0](https://github.com/argoproj/argo-workflows/blob/main/LICENSE) —
OSI-approved, meeting the appstore curation policy.
