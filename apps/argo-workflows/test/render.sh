#!/usr/bin/env bash
# Deterministic render test for the argo-workflows app entry.
#
# Fetches the EXACT pinned upstream chart, renders it twice with `helm template`
# into a throwaway directory, and asserts the shape of the output:
#
#   * workflow-controller and argo-server Deployments exist and are pinned to
#     real k3s agent nodes (outpost.dhnt.io/backend=k3s, kubernetes.io/os=linux);
#   * the ServiceAccounts and namespaced RBAC named in ../values.yaml exist;
#   * the workflow-controller ConfigMap carries the k3s workflowDefaults used
#     as defense in depth when a submission does not override placement;
#   * the digest-covered embedded CRDs render with keep semantics and no remote
#     GitHub install hook;
#   * every ClusterWorkflowTemplate binding resolves to a minimal read role;
#   * generated Argo executor containers have explicit bounded resources;
#   * with test/fixtures/enabled.values.yaml the workflow archive and the
#     S3-compatible artifact repository wire up to Secret REFERENCES, with no
#     credential material anywhere in the render.
#
# NO CLUSTER IS CONTACTED. `helm template` is client-side only. The single
# network access is the chart fetch from the pinned repo, and it is verified
# against test/chart.sha256 (see "Checksum" below).
#
# Requirements
#   helm 3.x. This host may not have one; there is no auto-download here by
#   design (an unverified binary fetch would be a worse trade than an explicit
#   dependency). Provide either:
#     * `helm` on PATH, or
#     * HELM_BIN=/path/to/helm ./test/render.sh
#   Plus python3 with PyYAML (same dependency as test/static.sh).
#
# Checksum
#   The fetched chart tarball's sha256 is compared against test/chart.sha256.
#   If that file is absent the test FAILS CLOSED. To record the digest on a
#   host you trust, run with ARGO_TRUST_ON_FIRST_USE=1: the digest is printed
#   (never written — this test leaves the repo clean) and you commit it by hand.
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/argo-workflows
#   ./test/render.sh
#
# Exit code: 0 = pass. Non-zero = failure, including "prerequisite missing".

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"

CHART_REPO="https://argoproj.github.io/argo-helm"
CHART_NAME="argo-workflows"
CHART_VERSION="1.0.20"           # MUST match apps/argo-workflows/app.yaml
APP_VERSION="4.0.7"              # Argo Workflows appVersion shipped by that chart

RELEASE="argo-render-test"
NAMESPACE="argo-render-test"

fail() { echo "FAIL: $*" >&2; exit 1; }

HELM="${HELM_BIN:-$(command -v helm 2>/dev/null || true)}"
[[ -n "$HELM" && -x "$HELM" ]] || fail "no helm binary.
      Install helm 3.x, or point HELM_BIN at one:
        HELM_BIN=/path/to/helm $0
      This test does not download a binary for you on purpose."
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
python3 -c 'import yaml' >/dev/null 2>&1 || fail "python3 PyYAML not importable"

case "$("$HELM" version --short 2>/dev/null || true)" in
  v3.*) : ;;
  *) fail "helm 3.x required, got: $("$HELM" version --short 2>/dev/null || echo unknown)" ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/argo-render.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Keep every side effect inside $TMP: no repo entries, no cache, no config are
# added to the invoking user's helm home.
export HELM_CACHE_HOME="$TMP/cache" HELM_CONFIG_HOME="$TMP/config" HELM_DATA_HOME="$TMP/data"
mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME" "$HELM_DATA_HOME"

echo "==> Fetching $CHART_NAME-$CHART_VERSION from $CHART_REPO"
"$HELM" pull "$CHART_NAME" --repo "$CHART_REPO" --version "$CHART_VERSION" \
  --destination "$TMP" >/dev/null || fail "helm pull failed (network? chart pin wrong?)"

TARBALL="$TMP/$CHART_NAME-$CHART_VERSION.tgz"
[[ -f "$TARBALL" ]] || fail "expected $TARBALL after helm pull"

if command -v sha256sum >/dev/null 2>&1; then
  GOT="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
else
  GOT="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
fi

if [[ -f "$HERE/chart.sha256" ]]; then
  WANT="$(tr -d '[:space:]' < "$HERE/chart.sha256")"
  [[ "$GOT" == "$WANT" ]] || fail "chart digest mismatch — refusing to render.
      expected $WANT
      got      $GOT
      Either the pin moved under you or the fetch was tampered with."
  echo "==> Chart digest verified: $GOT"
elif [[ "${ARGO_TRUST_ON_FIRST_USE:-0}" == "1" ]]; then
  echo "==> TRUST-ON-FIRST-USE: chart digest is $GOT"
  echo "    Record it (from a host you trust) with:"
  echo "      printf '%s\\n' '$GOT' > apps/argo-workflows/test/chart.sha256"
else
  fail "test/chart.sha256 is absent, so the fetched chart cannot be verified.
      Re-run once with ARGO_TRUST_ON_FIRST_USE=1 to print the digest, then
      commit it to apps/argo-workflows/test/chart.sha256."
fi

render() { # render <out-file> [extra helm args...]
  local out="$1"; shift
  "$HELM" template "$RELEASE" "$TARBALL" \
    --namespace "$NAMESPACE" \
    --include-crds \
    --values "$APP_DIR/values.yaml" \
    "$@" > "$out" || fail "helm template failed for $out"
}

echo "==> Rendering defaults (values.yaml)"
render "$TMP/default.yaml"

echo "==> Rendering with archive + S3 artifact repository enabled"
render "$TMP/enabled.yaml" --values "$HERE/fixtures/enabled.values.yaml"

echo "==> Asserting rendered output"
TMP="$TMP" APP_VERSION="$APP_VERSION" python3 - <<'PY'
import os, re, sys, pathlib, yaml

TMP = pathlib.Path(os.environ["TMP"])
APP_VERSION = os.environ["APP_VERSION"]
K3S = {"outpost.dhnt.io/backend": "k3s", "kubernetes.io/os": "linux"}

fails, checks = [], 0
def ck(cond, msg):
    global checks
    checks += 1
    if not cond:
        fails.append(msg)

def docs(name):
    text = (TMP / name).read_text()
    return text, [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]

def by_kind(ds, kind):
    return [d for d in ds if d.get("kind") == kind]

def named(ds, kind, frag):
    return [d for d in by_kind(ds, kind)
            if frag in (d.get("metadata") or {}).get("name", "")]

default_text, default_docs = docs("default.yaml")
ck(default_docs, "default render produced no documents")

# --- controller + server workloads -----------------------------------------
controllers = named(default_docs, "Deployment", "workflow-controller")
servers = [d for d in by_kind(default_docs, "Deployment")
           if "server" in (d.get("metadata") or {}).get("name", "")]
ck(len(controllers) == 1, f"expected exactly one workflow-controller Deployment, got {len(controllers)}")
ck(len(servers) == 1, f"expected exactly one argo-server Deployment, got {len(servers)}")

for d in controllers + servers:
    name = d["metadata"]["name"]
    pspec = (((d.get("spec") or {}).get("template") or {}).get("spec") or {})
    ck(pspec.get("nodeSelector") == K3S,
       f"{name}: nodeSelector must be exactly {K3S}, got {pspec.get('nodeSelector')}")
    ck(not pspec.get("tolerations"),
       f"{name}: must carry no tolerations (a virtual-kubelet toleration would let an Argo "
       f"pod land on vk-native)")
    ck(len(pspec.get("containers") or []) >= 1, f"{name}: no containers rendered")

# The chart's appVersion must be the one the catalog advertises.
imgs = [c.get("image", "") for d in controllers + servers
        for c in (((d.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", [])]
ck(any(APP_VERSION in i for i in imgs),
   f"no rendered image references Argo {APP_VERSION} — app.yaml's metadata.version disagrees "
   f"with the pinned chart's appVersion. Rendered images: {imgs}")

# --- service accounts + namespaced RBAC ------------------------------------
sa_names = {(d.get("metadata") or {}).get("name") for d in by_kind(default_docs, "ServiceAccount")}
for want in ("argo-workflows-controller", "argo-workflows-server", "argo-workflow"):
    ck(want in sa_names, f"ServiceAccount {want!r} not rendered (have: {sorted(sa_names)})")
ck(by_kind(default_docs, "Role"), "no namespaced Role rendered")
ck(by_kind(default_docs, "RoleBinding"), "no namespaced RoleBinding rendered")

# --- secure CRDs + complete ClusterWorkflowTemplate RBAC -------------------
cluster_scoped = [f"{d['kind']}/{(d.get('metadata') or {}).get('name')}"
                  for d in default_docs
                  if d.get("kind") in ("CustomResourceDefinition", "ClusterRole", "ClusterRoleBinding")]
cluster_roles = by_kind(default_docs, "ClusterRole")
ck(cluster_roles,
   "no ClusterRoles rendered, so app.yaml's clusterScoped:true would be over-declared")
crds = by_kind(default_docs, "CustomResourceDefinition")
expected_crds = {
    "clusterworkflowtemplates.argoproj.io",
    "cronworkflows.argoproj.io",
    "workflowartifactgctasks.argoproj.io",
    "workfloweventbindings.argoproj.io",
    "workflows.argoproj.io",
    "workflowtaskresults.argoproj.io",
    "workflowtasksets.argoproj.io",
    "workflowtemplates.argoproj.io",
}
crd_names = {(d.get("metadata") or {}).get("name") for d in crds}
ck(crd_names == expected_crds,
   f"default render must contain exactly the 8 chart-bundled CRDs, got {sorted(crd_names)}")
for d in crds:
    name = (d.get("metadata") or {}).get("name")
    annotations = (d.get("metadata") or {}).get("annotations") or {}
    ck(annotations.get("helm.sh/resource-policy") == "keep",
       f"{name}: CRD must carry helm.sh/resource-policy=keep")
ck(not named(default_docs, "Job", "crd-install"),
   "default render contains the remote full-CRD install Job")
ck("raw.githubusercontent.com" not in default_text,
   "default render references an undigested raw GitHub CRD source")

roles_by_name = {
    (d.get("metadata") or {}).get("name"): d for d in by_kind(default_docs, "ClusterRole")
}
cwt_bindings = [
    d for d in by_kind(default_docs, "ClusterRoleBinding")
    if (d.get("roleRef") or {}).get("name", "").endswith("-cluster-template")
]
ck(len(cwt_bindings) == 2,
   f"expected controller+server CWT ClusterRoleBindings, got {len(cwt_bindings)}")
for binding in cwt_bindings:
    bname = (binding.get("metadata") or {}).get("name")
    ref = (binding.get("roleRef") or {}).get("name")
    role = roles_by_name.get(ref)
    ck(role is not None, f"{bname}: dangling roleRef {ref!r}")
    if role:
        rules = role.get("rules") or []
        ck(len(rules) == 1
           and set(rules[0].get("resources") or [])
               == {"clusterworkflowtemplates", "clusterworkflowtemplates/finalizers"}
           and set(rules[0].get("verbs") or []) == {"get", "list", "watch"},
           f"{ref}: must grant only get/list/watch on CWTs and finalizers")
print("    cluster-scoped objects (why clusterScoped: true): "
      + ", ".join(sorted(cluster_scoped)[:4]) + f" ... [{len(cluster_scoped)} total]")

# --- controller ConfigMap: defense-in-depth workflow placement defaults -----
cms = [d for d in by_kind(default_docs, "ConfigMap")
       if "workflow-controller" in (d.get("metadata") or {}).get("name", "")]
ck(len(cms) == 1, f"expected one workflow-controller ConfigMap, got {len(cms)}")
if cms:
    data = cms[0].get("data") or {}
    config = yaml.safe_load(data.get("config", "")) or {}
    ck(isinstance(config, dict),
       f"controller ConfigMap data.config must contain a YAML mapping, got {type(config).__name__}")
    raw_wd = config.get("workflowDefaults") if isinstance(config, dict) else None
    wd = yaml.safe_load(raw_wd) if isinstance(raw_wd, str) else raw_wd
    wd = wd or {}
    ck(isinstance(wd, dict) and wd,
       f"controller ConfigMap data.config has no workflowDefaults (keys: "
       f"{sorted(config) if isinstance(config, dict) else []})")
    spec = wd.get("spec") or {} if isinstance(wd, dict) else {}
    ck(spec.get("nodeSelector") == K3S,
       f"workflowDefaults.spec.nodeSelector must be {K3S}, got {spec.get('nodeSelector')}")
    ck(spec.get("tolerations") == [],
       "workflowDefaults.spec.tolerations must render as an explicit empty list")
    ck(spec.get("serviceAccountName") == "argo-workflow",
       "workflowDefaults.spec.serviceAccountName must pin the workflow ServiceAccount")
    retry_limit = (spec.get("retryStrategy") or {}).get("limit")
    ck(isinstance(retry_limit, int) and retry_limit == 2,
       f"workflowDefaults.spec.retryStrategy.limit must render as integer 2, "
       f"got {retry_limit!r} ({type(retry_limit).__name__})")
    executor = config.get("executor") or {}
    if isinstance(executor, str):
        executor = yaml.safe_load(executor) or {}
    resources = executor.get("resources") or {} if isinstance(executor, dict) else {}
    requests, limits = resources.get("requests") or {}, resources.get("limits") or {}
    ck(requests.get("cpu") == "10m" and requests.get("memory") == "32Mi",
       f"controller ConfigMap executor requests are missing/unbounded: {requests}")
    ck(limits.get("cpu") == "100m" and limits.get("memory") == "128Mi",
       f"controller ConfigMap executor limits are missing/unbounded: {limits}")

# --- the package's default chart configuration must not target vk-native ----
ck("vk-native" not in default_text,
   "the default render mentions vk-native — package-managed chart objects and defaults "
   "must target k3s")

# --- namespaced authenticated artifact repository contract -----------------
aliases = [d for d in by_kind(default_docs, "Service")
           if (d.get("metadata") or {}).get("name") == "seaweedfs-s3"]
ck(len(aliases) == 1, f"expected one seaweedfs-s3 Service, got {len(aliases)}")
if aliases:
    ck(aliases[0].get("spec") == {
        "type": "ExternalName",
        "externalName": "seaweedfs-s3.seaweedfs-system.svc.cluster.local",
    }, f"seaweedfs-s3 must be the stable cross-namespace DNS alias, got "
       f"{aliases[0].get('spec')}")

repositories = [d for d in by_kind(default_docs, "ConfigMap")
                if (d.get("metadata") or {}).get("name") == "artifact-repositories"]
ck(len(repositories) == 1,
   f"expected one artifact-repositories ConfigMap, got {len(repositories)}")
if repositories:
    annotations = (repositories[0].get("metadata") or {}).get("annotations") or {}
    ck(annotations.get("workflows.argoproj.io/default-artifact-repository") == "seaweedfs-v1",
       "artifact-repositories must select seaweedfs-v1")
    raw_repository = (repositories[0].get("data") or {}).get("seaweedfs-v1", "")
    repository = yaml.safe_load(raw_repository) or {}
    ck(repository == {
        "s3": {
            "endpoint": "seaweedfs-s3:8333",
            "bucket": "argo-artifacts",
            "region": "us-east-1",
            "insecure": True,
            "keyFormat": "artifacts/{{workflow.namespace}}/{{workflow.uid}}/{{pod.name}}",
            "accessKeySecret": {"name": "argo-artifacts-s3", "key": "accesskey"},
            "secretKeySecret": {"name": "argo-artifacts-s3", "key": "secretkey"},
        }
    }, f"artifact-repositories/seaweedfs-v1 drifted: {repository!r}")

# --- enabled overlay: archive + artifacts by Secret reference only ---------
enabled_text, enabled_docs = docs("enabled.yaml")
ecms = [d for d in by_kind(enabled_docs, "ConfigMap")
        if "workflow-controller" in (d.get("metadata") or {}).get("name", "")]
ck(ecms, "no controller ConfigMap in the enabled render")
if ecms:
    blob = yaml.dump(ecms[0].get("data") or {})
    for token in ("accessKeySecret", "secretKeySecret", "argo-artifacts-s3", "argo-artifacts"):
        ck(token in blob, f"enabled render: controller ConfigMap missing {token!r} — the S3 "
                          f"artifact repository did not wire up")

persist = [d for d in enabled_docs if "persistence" in yaml.dump(d.get("data") or {})]
ck("passwordSecret" in enabled_text and "argo-archive-postgres" in enabled_text,
   "enabled render: the workflow archive did not wire up to a Secret reference")
ck("archive: true" in enabled_text or "archive:true" in enabled_text.replace(" ", ""),
   "enabled render: controller.persistence.archive did not take effect")

# No credential material may appear in either render.
for name, text in (("default", default_text), ("enabled", enabled_text)):
    for d in (yaml.safe_load_all(text)):
        if isinstance(d, dict) and d.get("kind") == "Secret":
            ck(False, f"{name} render emits a Secret ({(d.get('metadata') or {}).get('name')}) — "
                      f"credentials must be created out-of-band, never by this chart install")
    ck(not re.search(r"(?i)^\s*(accesskey|secretkey|password)\s*:\s*\S", text, re.M),
       f"{name} render contains an inline credential field")

print(f"ran {checks} assertions over {len(default_docs)} + {len(enabled_docs)} rendered documents")
if fails:
    print(f"\nFAIL — {len(fails)} assertion(s) failed:\n", file=sys.stderr)
    for f in fails:
        print(f"  * {f}", file=sys.stderr)
    sys.exit(1)
PY

echo "PASS — argo-workflows renders as specified (chart $CHART_NAME-$CHART_VERSION, argo v$APP_VERSION)"
