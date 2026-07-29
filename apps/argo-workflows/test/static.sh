#!/usr/bin/env bash
# Deterministic, offline, cluster-free validation of the argo-workflows app
# entry: catalog metadata invariants, YAML well-formedness, the placement
# invariants in values.yaml, and the vk-native indirection / no-fallback
# contract in smoke/.
#
# No cluster, no network, no `yq`. Requires bash + python3 with PyYAML (the
# same python3 the catalog's other scripts already assume — see STATS.md).
#
# Fails closed: a missing interpreter, an unparseable document, or a missing
# assertion input is a FAILURE, never a skip.
#
# Reproduce:
#   git clone https://github.com/dhnt/appstore
#   cd appstore/apps/argo-workflows
#   ./test/static.sh
#
# Exit code: 0 = all invariants hold, non-zero = at least one violated.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "FAIL: python3 not found — static.sh cannot validate YAML, refusing to pass" >&2
  exit 1
}
python3 -c 'import yaml' >/dev/null 2>&1 || {
  echo "FAIL: python3 PyYAML not importable — refusing to pass" >&2
  echo "      install it with: python3 -m pip install pyyaml" >&2
  exit 1
}

APP_DIR="$APP_DIR" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import os, re, sys, pathlib, yaml

APP  = pathlib.Path(os.environ["APP_DIR"])
ROOT = pathlib.Path(os.environ["REPO_ROOT"])

# Single source of truth for the pin. Everything else must agree with it.
CHART_VERSION = "1.0.20"
APP_VERSION   = "4.0.7"

fails, checks = [], 0
def ck(cond, msg):
    global checks
    checks += 1
    if not cond:
        fails.append(msg)

def load(rel, multi=False):
    p = APP / rel if not str(rel).startswith("/") else pathlib.Path(rel)
    if not p.exists():
        fails.append(f"missing required file: {rel}")
        return [] if multi else None
    text = p.read_text()
    try:
        return list(yaml.safe_load_all(text)) if multi else yaml.safe_load(text)
    except yaml.YAMLError as e:
        fails.append(f"{rel}: not parseable YAML: {e}")
        return [] if multi else None

def dig(obj, *path, default=None):
    for k in path:
        if not isinstance(obj, dict) or k not in obj:
            return default
        obj = obj[k]
    return obj

def uncommented(text):
    """Drop whole-line YAML comments so prose about a forbidden construct is not
    mistaken for the construct itself."""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))

def walk(node):
    """Yield every (key, value) pair anywhere in a nested structure."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield k, v
            yield from walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v)

# ===========================================================================
# 1. Catalog metadata (CONTRIBUTING.md "app.yaml schema")
# ===========================================================================
app = load("app.yaml") or {}
md, spec = app.get("metadata") or {}, app.get("spec") or {}

ck(app.get("apiVersion") == "appstore.dhnt.io/v1", "app.yaml: wrong apiVersion")
ck(app.get("kind") == "AppEntry", "app.yaml: kind must be AppEntry")
ck(set(app) <= {"apiVersion", "kind", "metadata", "spec"},
   f"app.yaml: unknown top-level keys {sorted(set(app) - {'apiVersion','kind','metadata','spec'})} "
   "— the AppEntry schema has no such field and cloudbox ignores it silently")

ck(md.get("id") == APP.name, f"app.yaml: metadata.id must equal the directory name {APP.name!r}")
ck(re.fullmatch(r"[a-z0-9-]+", str(md.get("id", ""))) and len(str(md.get("id", ""))) <= 63,
   "app.yaml: metadata.id must be a <=63 char DNS label [a-z0-9-]+")
ck(str(md.get("version")) == APP_VERSION,
   f"app.yaml: metadata.version must be {APP_VERSION!r} (the pinned chart's appVersion)")
ck(md.get("visibility") in ("public", "members", "private"),
   "app.yaml: metadata.visibility must be public|members|private")
ck(isinstance(md.get("featured"), bool), "app.yaml: metadata.featured must be a bool")
ck(str(md.get("homepage", "")).startswith("https://"), "app.yaml: homepage must be https")
ck(len(str(md.get("description", "")).strip()) > 40, "app.yaml: description too short for the catalog grid")
ck(isinstance(md.get("maintainers"), list) and md["maintainers"]
   and all("email" in m for m in md["maintainers"]),
   "app.yaml: metadata.maintainers must be a non-empty list with an email each")

known = load(str(ROOT / "categories.yaml")) or {}
known_ids = {c["id"] for c in (known.get("categories") or [])}
ck(known_ids, "categories.yaml: could not read the category taxonomy")
unknown_cats = set(md.get("categories") or []) - known_ids
ck(not unknown_cats, f"app.yaml: categories not in categories.yaml: {sorted(unknown_cats)}")

chart = dig(spec, "chart", default={}) or {}
ck(chart.get("repo") == "https://argoproj.github.io/argo-helm", "app.yaml: unexpected chart repo")
ck(chart.get("name") == "argo-workflows", "app.yaml: unexpected chart name")
ck(str(chart.get("version")) == CHART_VERSION,
   f"app.yaml: spec.chart.version must be the exact pin {CHART_VERSION!r}")
ck(re.fullmatch(r"\d+\.\d+\.\d+", str(chart.get("version", ""))),
   "app.yaml: spec.chart.version must be exact semver — loose ranges break repeatable installs")
ck(spec.get("targetNamespace") == "{{.UserNamespace}}",
   "app.yaml: targetNamespace vocabulary is limited to {{.UserNamespace}}")
ck(spec.get("defaultValuesFile") == "values.yaml", "app.yaml: defaultValuesFile must be values.yaml")
ck((APP / "values.yaml").exists(), "values.yaml is missing")
ck(isinstance(dig(spec, "rbac", "clusterScoped"), bool), "app.yaml: spec.rbac.clusterScoped must be a bool")

# ===========================================================================
# 2. Truthfulness: a chart that installs CRDs cannot claim no cluster scope
# ===========================================================================
values = load("values.yaml") or {}
crds_install = dig(values, "crds", "install", default=True)
ck(dig(spec, "rbac", "clusterScoped") is True or crds_install is False,
   "app.yaml/values.yaml: crds.install=true creates cluster-scoped CustomResourceDefinitions, "
   "so spec.rbac.clusterScoped MUST be true")
ck(dig(values, "crds", "keep") is True,
   "values.yaml: crds.keep must be true — otherwise `helm uninstall` cascade-deletes every "
   "Workflow object on the cluster")
ck(values.get("createAggregateRoles") is False,
   "values.yaml: createAggregateRoles must be false — a per-user install must not mutate the "
   "cluster's aggregated view/edit/admin ClusterRoles")
ck(values.get("singleNamespace") is True, "values.yaml: singleNamespace must be true")

# ===========================================================================
# 3. Placement: every Argo-owned pod is pinned to real k3s agent nodes
# ===========================================================================
K3S = {"outpost.dhnt.io/backend": "k3s", "kubernetes.io/os": "linux"}
for where, sel in (
    ("controller",                         dig(values, "controller", "nodeSelector")),
    ("server",                             dig(values, "server", "nodeSelector")),
    ("controller.workflowDefaults.spec",   dig(values, "controller", "workflowDefaults", "spec", "nodeSelector")),
):
    ck(sel == K3S, f"values.yaml: {where}.nodeSelector must be exactly {K3S} — Argo's "
                   "executor/init/wait lifecycle is unsupported on vk-native")
for where, tol in (
    ("controller",                       dig(values, "controller", "tolerations", default=None)),
    ("server",                           dig(values, "server", "tolerations", default=None)),
    ("controller.workflowDefaults.spec", dig(values, "controller", "workflowDefaults", "spec", "tolerations", default=None)),
):
    ck(tol == [], f"values.yaml: {where}.tolerations must be explicitly [] — any virtual-kubelet "
                  "toleration readmits the failure mode the nodeSelector rules out")

values_text = uncommented((APP / "values.yaml").read_text())
ck("preferredDuringScheduling" not in values_text,
   "values.yaml: soft (preferred) affinity is forbidden — placement must be a hard requirement "
   "with no fallback")
ck(not re.search(r"^\s*[^#\n]*vk-native", values_text, re.M),
   "values.yaml: no uncommented reference to vk-native may appear — Argo pods never run there")

# ===========================================================================
# 4. No embedded credentials anywhere in the app entry
# ===========================================================================
SECRET_KEYS = re.compile(r"(?i)(password|passwd|secretkey|accesskey|access_key|secret_key|token|apikey|api_key)$")
for f in sorted(APP.rglob("*.yaml")):
    rel = f.relative_to(APP)
    try:
        docs = list(yaml.safe_load_all(f.read_text()))
    except yaml.YAMLError as e:
        fails.append(f"{rel}: not parseable YAML: {e}")
        continue
    for doc in docs:
        for k, v in walk(doc):
            checks += 1
            if isinstance(k, str) and SECRET_KEYS.search(k) and isinstance(v, (str, int, bool)):
                fails.append(f"{rel}: key {k!r} carries a literal value — credentials must be "
                             f"Secret references only")
# The artifact repository must be wired by reference, never inline.
s3 = dig(values, "artifactRepository", "s3", default=None)
if s3 is not None:
    ck(isinstance(dig(s3, "accessKeySecret"), dict) and isinstance(dig(s3, "secretKeySecret"), dict),
       "values.yaml: artifactRepository.s3 must use accessKeySecret/secretKeySecret references")
ck("artifactRepository" in values, "values.yaml: artifactRepository stanza (even if empty) must be present "
                                   "so operators have a documented hook")
ck(dig(values, "artifactRepository", "archiveLogs") is False,
   "values.yaml: artifactRepository.archiveLogs must default to false — an out-of-the-box install "
   "has no bucket to write to")

# ===========================================================================
# 5. Docs + icon
# ===========================================================================
readme = (APP / "README.md").read_text() if (APP / "README.md").exists() else ""
ck(readme, "README.md is missing")
ck("## License" in readme, "README.md: a one-line '## License' section is mandatory (CONTRIBUTING.md)")
ck("Apache-2.0" in readme, "README.md: must name the upstream license")
ck(CHART_VERSION in readme, f"README.md: must state the pinned chart version {CHART_VERSION}")
ck(APP_VERSION in readme, f"README.md: must state the Argo appVersion {APP_VERSION}")
for section in ("## Tested performance", "## Reproducing these numbers"):
    ck(section in readme, f"README.md: missing '{section}' section (CONTRIBUTING.md checklist)")

icon = (APP / "icon.svg")
ck(icon.exists(), "icon.svg is missing")
if icon.exists():
    svg = icon.read_text()
    ck('viewBox="0 0 64 64"' in svg, "icon.svg: must use a 64x64 viewBox")
    # The SVG namespace declaration is the only permitted http(s) occurrence:
    # no <image href>, no external stylesheet, nothing fetched at render time.
    ck("href" not in svg, "icon.svg: must be inline-only — no href/xlink:href references")
    ck(not re.search(r"https?://(?!www\.w3\.org/2000/svg)", svg),
       "icon.svg: must be inline-only — the only allowed URL is the SVG namespace")

# The pin must appear in the render test too, so a bump cannot half-land.
render = (APP / "test/render.sh")
ck(render.exists(), "test/render.sh is missing")
if render.exists():
    ck(f'CHART_VERSION="{CHART_VERSION}"' in render.read_text(),
       f"test/render.sh: chart pin drifted from app.yaml ({CHART_VERSION})")

# ===========================================================================
# 6. The vk-native indirection contract
# ===========================================================================
smoke_path = APP / "smoke/vk-native-indirection.yaml"
ck(smoke_path.exists(), "smoke/vk-native-indirection.yaml is missing")
if smoke_path.exists():
    raw = uncommented(smoke_path.read_text())
    wt = load("smoke/vk-native-indirection.yaml") or {}
    wspec = wt.get("spec") or {}

    ck(wt.get("apiVersion") == "argoproj.io/v1alpha1" and wt.get("kind") == "WorkflowTemplate",
       "smoke: must be an argoproj.io/v1alpha1 WorkflowTemplate")

    # --- 6a. Argo-owned pods pinned to k3s, no fallback ---
    ck(wspec.get("nodeSelector") == K3S,
       f"smoke: workflow spec.nodeSelector must be exactly {K3S}")
    ck(wspec.get("tolerations") == [], "smoke: workflow spec.tolerations must be explicitly []")
    ck("preferredDuringScheduling" not in raw,
       "smoke: soft affinity is forbidden — a fallback would let Argo pods reach vk-native")
    ck("affinity" not in raw, "smoke: use nodeSelector, not affinity — hard placement only")

    # --- 6b. Argo never runs a container itself; it only uses `resource` ---
    templates = wspec.get("templates") or []
    ck(templates, "smoke: no templates defined")
    for t in templates:
        ck(not any(k in t for k in ("container", "script", "containerSet")),
           f"smoke: template {t.get('name')!r} runs a container directly — the payload must be "
           "reached indirectly through a `resource` template")
    by_name = {t.get("name"): t for t in templates}
    creator = by_name.get("create-watch-job") or {}
    res = creator.get("resource") or {}
    ck(res.get("action") == "create", "smoke: create-watch-job must be a resource/create template")
    ck(res.get("setOwnerReference") is True, "smoke: setOwnerReference must be true so an orphaned "
                                             "Job is still garbage-collected")
    ck(bool(res.get("successCondition")) and bool(res.get("failureCondition")),
       "smoke: BOTH successCondition and failureCondition are required — a Job that can never be "
       "scheduled must fail the workflow, not pass by omission")
    deleter = (by_name.get("delete-job") or {}).get("resource") or {}
    ck(deleter.get("action") == "delete", "smoke: a resource/delete template is required")
    ck(wspec.get("onExit") == "delete-job",
       "smoke: onExit must run the delete template so the Job is reaped on failure and "
       "cancellation too")
    ck("kubectl logs" not in raw and "kubectl exec" not in raw and "\nlog:" not in raw,
       "smoke: vk-native supports neither logs nor exec — the workflow must not depend on them")

    # --- 6c. Required, digest-pinned image parameter ---
    params = {p["name"]: p for p in (dig(wspec, "arguments", "parameters") or [])}
    for required in ("job-image", "job-command"):
        ck(required in params, f"smoke: parameter {required!r} must be declared")
        ck("value" not in params.get(required, {"value": None}),
           f"smoke: parameter {required!r} must have NO default — it is a required submit-time "
           "input (there is no truthful cross-OS default)")
    for defaulted in ("target-os", "target-arch"):
        ck(params.get(defaulted, {}).get("value"),
           f"smoke: parameter {defaulted!r} must be declared with an explicit default")

    # --- 6d. The Job manifest: exactly the vk-native envelope ---
    manifest_raw = res.get("manifest") or ""
    ck("{{workflow.parameters.job-image}}" in manifest_raw,
       "smoke: the Job image must come from the required job-image parameter, never a literal "
       "mutable tag")
    ck(not re.search(r"image:\s*[\"']?[\w./-]+:[\w.-]+[\"']?\s*$", manifest_raw, re.M),
       "smoke: no literal tagged image may appear — submit-time values must be digest-pinned")

    subbed = manifest_raw.replace("{{workflow.parameters.job-command}}", '["/bin/true"]')
    subbed = re.sub(r"\{\{[^}]*\}\}", "PLACEHOLDER", subbed)
    try:
        job = yaml.safe_load(subbed)
    except yaml.YAMLError as e:
        job = None
        fails.append(f"smoke: embedded Job manifest is not parseable YAML: {e}")

    if job:
        jspec = job.get("spec") or {}
        pspec = dig(jspec, "template", "spec", default={}) or {}
        ck(job.get("apiVersion") == "batch/v1" and job.get("kind") == "Job",
           "smoke: the indirected object must be an ordinary batch/v1 Job")
        # no fallback in time
        ck(jspec.get("backoffLimit") == 0,
           "smoke: backoffLimit must be 0 — a retry is a fallback onto another node")
        ck(isinstance(jspec.get("activeDeadlineSeconds"), int) and jspec.get("activeDeadlineSeconds") > 0,
           "smoke: Job spec.activeDeadlineSeconds must be set — an unschedulable vk-native "
           "payload remains Pending without incrementing status.failed, so the resource watch "
           "can otherwise wait forever instead of failing closed")
        ck(jspec.get("completions") == 1 and jspec.get("parallelism") == 1,
           "smoke: completions and parallelism must both be 1")
        ck(pspec.get("restartPolicy") == "Never", "smoke: Job pod restartPolicy must be Never")
        # hard placement onto native nodes, os+arch explicit
        sel = pspec.get("nodeSelector") or {}
        ck(sel.get("outpost.dhnt.io/backend") == "vk-native",
           "smoke: the payload pod must select outpost.dhnt.io/backend=vk-native")
        ck(set(sel) == {"outpost.dhnt.io/backend", "kubernetes.io/os", "kubernetes.io/arch"},
           f"smoke: payload nodeSelector must be exactly backend+os+arch, got {sorted(sel)}")
        ck("{{workflow.parameters.target-os}}" in manifest_raw
           and "{{workflow.parameters.target-arch}}" in manifest_raw,
           "smoke: kubernetes.io/os and kubernetes.io/arch must come from explicit parameters")
        # tolerates virtual-kubelet
        tols = pspec.get("tolerations") or []
        ck(len(tols) == 1 and tols[0].get("operator") == "Exists" and tols[0].get("effect") == "NoSchedule",
           "smoke: the payload pod needs exactly one Exists/NoSchedule toleration for the "
           "virtual-kubelet taint")
        ck("{{workflow.parameters.vk-taint-key}}" in manifest_raw,
           "smoke: the virtual-kubelet taint key must be a parameter, not hardcoded per fleet")
        # the vk-native capability envelope, and nothing beyond it
        containers = pspec.get("containers") or []
        ck(len(containers) == 1, f"smoke: vk-native supports exactly one container, got {len(containers)}")
        ck(not pspec.get("initContainers"), "smoke: vk-native supports no init containers")
        ck(not pspec.get("ephemeralContainers"), "smoke: vk-native supports no ephemeral containers")
        ck(not pspec.get("volumes"), "smoke: vk-native supports no volumes")
        ck(pspec.get("automountServiceAccountToken") is False,
           "smoke: automountServiceAccountToken must be false — the default SA token is a "
           "projected volume, which vk-native cannot mount")
        for c in containers:
            ck(not c.get("envFrom"), "smoke: vk-native supports no envFrom")
            ck(not c.get("volumeMounts"), "smoke: vk-native supports no volumeMounts")
            ck(all("value" in e and "valueFrom" not in e for e in (c.get("env") or [])),
               "smoke: vk-native supports literal env only — no valueFrom/secretKeyRef")
            ck(c.get("command"), "smoke: the payload container must declare an explicit command")

# ===========================================================================
# 7. Smoke RBAC stays namespaced
# ===========================================================================
rbac_docs = [d for d in load("smoke/rbac.yaml", multi=True) if d]
ck(rbac_docs, "smoke/rbac.yaml is missing or empty")
kinds = {d.get("kind") for d in rbac_docs}
ck(kinds == {"Role", "RoleBinding"},
   f"smoke/rbac.yaml: must contain exactly a Role and a RoleBinding, got {sorted(kinds)}")
ck(not any(str(d.get("kind", "")).startswith("Cluster") for d in rbac_docs),
   "smoke/rbac.yaml: no ClusterRole/ClusterRoleBinding — the smoke grant is namespace-scoped")
for d in rbac_docs:
    for rule in (d.get("rules") or []):
        ck("*" not in (rule.get("verbs") or []) and "*" not in (rule.get("resources") or []),
           "smoke/rbac.yaml: wildcard verbs/resources are forbidden")
        ck("pods/log" not in (rule.get("resources") or [])
           and "pods/exec" not in (rule.get("resources") or []),
           "smoke/rbac.yaml: granting pods/log or pods/exec implies a capability vk-native "
           "does not have")
sa_names = {s.get("name") for d in rbac_docs if d.get("kind") == "RoleBinding"
            for s in (d.get("subjects") or [])}
ck(sa_names == {dig(values, "workflow", "serviceAccount", "name")},
   "smoke/rbac.yaml: RoleBinding subject must be values.yaml's workflow.serviceAccount.name")

# ===========================================================================
print(f"ran {checks} assertions")
if fails:
    print(f"\nFAIL — {len(fails)} invariant(s) violated:\n", file=sys.stderr)
    for f in fails:
        print(f"  * {f}", file=sys.stderr)
    sys.exit(1)
print("PASS — argo-workflows static/schema/contract invariants hold")
PY
