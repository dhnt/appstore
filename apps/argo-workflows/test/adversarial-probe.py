#!/usr/bin/env python3
"""Adversarial probe battery for the argo-workflows package.

Each numbered probe preserves a regression found by adversarial review. The
normal static gate invokes this file so these checks cannot be omitted.

Run from the app directory:
    python3 test/adversarial-probe.py .

Exit code: 0 = all regressions are fixed, non-zero = defect(s) confirmed.
"""

import pathlib, re, sys, yaml

APP = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.cwd()

FAILS = []
CHECKS = 0


def ck(cond, label, msg):
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append((label, msg))


# ---- Load production files ------------------------------------------------
values = yaml.safe_load((APP / "values.yaml").read_text())
smoke = yaml.safe_load((APP / "smoke/vk-native-indirection.yaml").read_text())

K3S = {"outpost.dhnt.io/backend": "k3s", "kubernetes.io/os": "linux"}

# ---- Extract the smoke Job manifest block scalar ---------------------------
manifest_raw = ""
for t in (smoke.get("spec") or {}).get("templates") or []:
    if t.get("name") == "create-watch-job":
        manifest_raw = (t.get("resource") or {}).get("manifest", "")
        break

params = {}
for p in (
    (smoke.get("spec") or {}).get("arguments") or {}
).get("parameters") or []:
    params[p["name"]] = p


# ===========================================================================
# PROBE 1 — retryStrategy.limit is a YAML string, not an integer
#
# values.yaml line 79:  limit: "2"
#
# The Argo CRD types this field as *intstr.IntOrString, which accepts both
# forms, but the upstream Helm chart and documentation consistently use the
# integer form.  Writing it as a quoted YAML string misleads operators and
# signals the author did not understand the field accepts a bare numeric.
# ===========================================================================
limit = (
    values.get("controller", {})
    .get("workflowDefaults", {})
    .get("spec", {})
    .get("retryStrategy", {})
    .get("limit")
)
ck(
    isinstance(limit, int),
    "retryStrategy.limit: YAML string where integer is expected",
    f"  values.yaml line 79:  limit: \"2\"\n"
    f"  Parsed as:  {limit!r} (type {type(limit).__name__})\n"
    f"  Upstream Argo Helm chart default:  limit: 2  (bare integer)\n"
    f"  While IntOrString tolerates the string form, this is semantically a\n"
    f"  number — quoting it signals misunderstanding of the type.  If Argo\n"
    f"  ever tightens validation, a string will be rejected.",
)

# ===========================================================================
# PROBE 2 — the smoke usage pointer resolves to the real README section
#
# Keep the pointer and target heading coupled so a future rename cannot leave
# operators following a dead relative path.
# ===========================================================================
readme_text = (APP / "README.md").read_text()
smoke_text = (APP / "smoke/vk-native-indirection.yaml").read_text()
ck(
    "Usage: see ../README.md#vk-native-indirection-smoke." in smoke_text
    and "## vk-native indirection smoke" in readme_text,
    "smoke usage pointer does not resolve to the main README section",
    f"  smoke/vk-native-indirection.yaml must point to\n"
    f"  ../README.md#vk-native-indirection-smoke, and README.md must retain\n"
    f"  the matching '## vk-native indirection smoke' heading.",
)

# ===========================================================================
# PROBE 3 — activeDeadlineSeconds: leading-zero octal footgun
#
# The manifest must convert the parameter before unquoted substitution:
#   activeDeadlineSeconds: {{=asInt(workflow.parameters['...'])}}
#
# Without conversion, inputs such as "0300" and "0100" reach YAML 1.1 as octal
# scalars. Simulate Argo's asInt result and require decimal Kubernetes integers.
# ===========================================================================
deadline_default = params.get("job-active-deadline-seconds", {}).get("value", "INVALID")

deadline_expr = "{{=asInt(workflow.parameters['job-active-deadline-seconds'])}}"
failed_any_octal = True
detail_lines = ["    required manifest or deadline parameter is missing"]
if manifest_raw and deadline_default != "INVALID":
    failed_any_octal = False
    detail_lines = []
    for test_val in ("0300", "0100"):
        subbed = manifest_raw.replace(
            "{{workflow.parameters.job-command}}", '["/bin/true"]'
        )
        subbed = subbed.replace(deadline_expr, str(int(test_val, 10)))
        subbed = re.sub(r"\{\{[^}]*\}\}", "PLACEHOLDER", subbed)
        try:
            job = yaml.safe_load(subbed)
            ads = job.get("spec", {}).get("activeDeadlineSeconds")
            expected = int(test_val)
            if ads != expected:
                failed_any_octal = True
                detail_lines.append(
                    f"    {test_val!r} -> YAML octal {ads}, expected decimal {expected}"
                )
        except yaml.YAMLError:
            failed_any_octal = True
            detail_lines.append(f"    {test_val!r} -> YAML parse error")

ck(
    deadline_expr in manifest_raw and not failed_any_octal,
    "activeDeadlineSeconds: leading zeros trigger YAML 1.1 octal parsing",
    f"  The smoke manifest must use an asInt expression before unquoted\n"
    f"  substitution. Leading-zero inputs must render as decimal:\n"
    + "\n".join(detail_lines)
    + f"\n"
    f"  Expected expression: {deadline_expr}",
)

# ===========================================================================
# PROBE 4 — delete-job onExit handler is not idempotent
#
# The onExit handler runs `kubectl delete job <name> -n <ns>` without
# --ignore-not-found.  If the Job does not exist (workflow cancelled before
# the resource step ran, or the Job was GC'd by ownerReferences), kubectl
# exits non-zero.  Argo can mark the workflow Failed even when the main
# body succeeded.
# ===========================================================================
deleter_flags = None
for t in (smoke.get("spec") or {}).get("templates") or []:
    if t.get("name") == "delete-job":
        deleter_flags = (t.get("resource") or {}).get("flags") or []

ck(
    deleter_flags is not None and "--ignore-not-found" in deleter_flags,
    "delete-job exit handler: missing --ignore-not-found (not idempotent)",
    f"  onExit handler flags:  {deleter_flags!r}\n"
    f"  If the Job does not exist — cancelled before creation, already\n"
    f"  garbage-collected — kubectl delete exits non-zero and the Argo\n"
    f"  resource template marks the exit handler as failed.  Add\n"
    f"  --ignore-not-found to make the delete idempotent.",
)

# ===========================================================================
# PROBE 5 — test production boundaries, not a hardcoded fixture tautology
#
# The old check merged hardcoded selectors and passed regardless of production.
# Require its fixture symbols to stay gone and verify the actual user-facing
# boundary: defaults are not admission, while smoke pins its own Argo pods.
# ===========================================================================
static_text = (APP / "test/static.sh").read_text()
smoke_spec = smoke.get("spec") or {}
boundary_phrases = (
    "defense-in-depth defaulting, not admission enforcement",
    "can override the defaults",
    "external admission policy",
)

ck(
    not any(name in static_text for name in (
        "adversarial_selector", "merged_selector", "merged_tolerations"
    ))
    and all(phrase in readme_text for phrase in boundary_phrases)
    and smoke_spec.get("nodeSelector") == K3S
    and smoke_spec.get("tolerations") == [],
    "production placement boundary assertions are incomplete",
    f"  test/static.sh must not retain the hardcoded adversarial fixture.\n"
    f"  README.md must distinguish workflow defaults from admission, and\n"
    f"  the smoke WorkflowTemplate must explicitly select exactly {K3S}\n"
    f"  with empty tolerations.",
)

# ===========================================================================
# Report
# ===========================================================================
print(f"Ran {CHECKS} adversarial probe assertions over {APP}")
if FAILS:
    print(f"\nFAIL — {len(FAILS)} defect(s) confirmed:\n", file=sys.stderr)
    for label, msg in FAILS:
        print(f"  [{label}]", file=sys.stderr)
        print(f"{msg}\n", file=sys.stderr)
    sys.exit(1)
else:
    print("All adversarial probes passed — no defects found.")
    sys.exit(0)
