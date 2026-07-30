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

| Mode | CRD values | Who can install | Notes |
|---|---|---|---|
| **Secure default** | `install: true`, `full: false`, `keep: true` | cloudbox-admin (clusterScoped gate) | Installs the minimal CRDs embedded in the sha256-pinned chart archive. Uninstall retains them and cannot cascade-delete Workflow objects. |
| **Full CRDs pre-applied** | `install: false` | admin preflight, then namespace installer | An admin obtains the exact full CRDs through a separately pinned, digest-verified process and applies them cluster-wide; the per-user release does not run a CRD hook. |

Chart `1.0.20` implements `crds.full=true` with a pre-install/pre-upgrade Job
that downloads eight files from `raw.githubusercontent.com` under a mutable Git
tag. The chart archive checksum does not authenticate those later responses.
The package therefore sets `full: false` and renders no remote CRD hook.

The embedded minimal CRD set uses `x-kubernetes-preserve-unknown-fields` for
large Argo object sections: the API server stores the complete object, but the
set provides less field-by-field OpenAPI validation than the full CRDs.
Operators who require full schema validation must pre-apply full CRDs whose
bytes and digest are pinned independently, then install with
`crds.install=false`. Do not override `full=true` directly in this package.

Chart `1.0.20` also emits ClusterRoleBindings for ClusterWorkflowTemplate access
in `singleNamespace` mode while suppressing their referenced ClusterRoles.
`values.yaml` supplies the two missing roles through `extraObjects`, with only
`get/list/watch` on ClusterWorkflowTemplates and their finalizers.

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

Argo's generated init/wait executor containers have explicit small resource
requests and limits in `values.yaml`. This prevents tenant LimitRanges from
silently assigning 500m or 1 CPU per generated container and quota-blocking a
small fan-out. The package deliberately does not default resources for the
user's main container; each Workflow author remains responsible for those.

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
| guarded deadline and taint-key inputs | Job | non-positive deadlines and empty taint keys make the Job API-invalid before a pod exists |
| explicit `failureCondition` | resource template | Argo observes the Job failure; it cannot pass by omission |
| `pods/log`, `pods/exec` not granted | `smoke/rbac.yaml` | granting them would imply a capability vk-native does not have |

`test/static.sh` asserts every row of that table.

### Running it

```bash
kubectl -n <ns> apply -f smoke/rbac.yaml            # namespaced Role + RoleBinding
kubectl -n <ns> apply -f smoke/vk-native-indirection.yaml
argo -n <ns> submit --from workflowtemplate/vk-native-indirection-smoke \
  -p native-artifact-url='https://example.invalid/releases/tool-linux-arm64.tar.gz' \
  -p native-artifact-sha256='<64 lowercase hex characters>' \
  -p native-artifact-path='tool' \
  -p job-command='["tool","smoke"]' \
  -p target-os=linux -p target-arch=arm64 \
  -p job-active-deadline-seconds=600 --wait
```

`job-command`, `native-artifact-url`, `native-artifact-sha256`, and
`native-artifact-path` are **required parameters with no defaults**. Together
they express the actual native execution contract:

- `dhnt.io/native-process` is a marker image. vk-native does not pull an OCI
  filesystem or execute a binary from one.
- The URL must use HTTPS (loopback HTTP is allowed for a locally controlled
  source), and the SHA-256 covers the complete downloaded archive.
- The member path selects one regular executable from a `.tar.gz`, `.tgz`, or
  `.zip` archive. The backend rejects missing tuple members, unsafe paths,
  checksum mismatches, transport downgrades, and unsupported archives.
- A native fleet may be linux/darwin/windows on amd64/arm64. The explicit
  `target-os` and `target-arch` must match the supplied executable. This ships
  as a *template plus a tested structure*, not as a turnkey command.

`test/fixtures/native-artifact.parameters.yaml` shows the complete parameter
shape. Replace every example value with the immutable release artifact for the
selected OS and architecture before submission.

The virtual-kubelet taint key is the `vk-taint-key` parameter (default
`virtual-kubelet.io/provider`); override it with a non-empty Kubernetes taint
key if your fleet taints differently. An empty key with `operator: Exists`
would match every `NoSchedule` taint, but it would **not** bypass the mandatory
`outpost.dhnt.io/backend=vk-native`, OS, and architecture `nodeSelector`
requirements. The template nevertheless guards empty input by rendering an
API-invalid key, so Kubernetes rejects the Job before any payload pod exists.

The Job also has a native scheduler boundary:
`job-active-deadline-seconds` defaults to **300 seconds**. If no matching
vk-native node can schedule the payload, Kubernetes keeps the pod Pending until
this positive deadline expires, marks the Job failed, and the Argo resource
template observes that terminal failure through its existing
`failureCondition`. Override it at submission with
`-p job-active-deadline-seconds=<positive-seconds>` to match fleet scheduling
latency. The Kubernetes Job API requires `activeDeadlineSeconds` to be greater
than zero; the template explicitly maps non-positive input to API-invalid `-1`,
so submission fails closed before a viable Job can schedule. This is additional
to, and does not replace, the workflow/task timeout semantics enforced by Argo.

## Reusable mixed DKS dispatcher

`dispatch/mixed-dks.yaml` promotes the proven indirection into a bounded
`WorkflowTemplate`: a required OCI image/script runs on real Linux k3s, then
Argo creates and watches one ordinary native Job. The native payload is hard
selected by backend, stable `outpost.dhnt.io/host`, OS, and architecture and
executes only the required verified-URL/SHA-256/member-path tuple through the
`dhnt.io/native-process` marker.

Apply `smoke/rbac.yaml` once in the workflow namespace; its namespaced Job
grant is also the dispatcher grant. Required inputs are immutable
`k3s-image` (`name@sha256:<64 lowercase hex>`), JSON/YAML argv
`k3s-command`, `target-host`, `job-command`, and the three native artifact
parameters. None transports a secret. Native failure propagates through Job
status, a positive deadline, `backoffLimit: 0`, and the resource template's
explicit `failureCondition`; there is no log, exec, retry, or backend fallback.
The k3s command is merged directly into `container.command` with
`podSpecPatch`; no shell parses or reinterprets workload text. Argo expression
guards map malformed/empty argv to an invalid Pod patch, mutable images to an
empty image, and malformed native URL/digest/path inputs to empty required
fields, making Pod creation or the native backend fail closed. Artifact
transport is HTTPS, except for the backend's deliberately narrow locally
controlled proof path: HTTP to literal `localhost` or `127.0.0.1`, with an
optional port and a non-empty path.

Output artifact collection is deliberately outside this v1 contract. A native
payload must publish results to an authenticated endpoint itself, followed by
a real-k3s evidence-validation step before promotion.

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
| `test/render.sh` | `helm` 3.x (or `HELM_BIN=…`), `python3` + PyYAML, network | fetches the exact pinned chart into a temp dir, verifies its sha256 against `test/chart.sha256`, renders twice (defaults, and with archive + S3 enabled), and rejects remote CRD hooks, dangling ClusterWorkflowTemplate bindings, or unbounded executor resources |

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
