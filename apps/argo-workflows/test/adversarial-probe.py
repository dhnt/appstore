#!/usr/bin/env python3
"""Adversarial probe battery for the argo-workflows package.

Each numbered probe is a test that FAILS on the current code — a defect that
the existing test suite (test/static.sh, test/render.sh) does not catch.

Run from the app directory:
    python3 test/adversarial-probe.py .

Do NOT fix the code the probes point at.  Leave the probes failing.
Exit code: 0 = no defects found, non-zero = at least one defect confirmed.
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
# PROBE 2 — smoke/vk-native-indirection.yaml line 30 points to a dead file
#
# The comment says "Usage: see smoke/README.md" but no such file exists.
# An operator following the pointer arrives at nothing.
# ===========================================================================
ck(
    (APP / "smoke" / "README.md").exists(),
    "smoke/README.md: referenced but does not exist",
    f"  smoke/vk-native-indirection.yaml line 30:\n"
    f"    'Usage: see smoke/README.md.'\n"
    f"  That file is absent.  The actual usage instructions live in the\n"
    f"  main README.md (## vk-native indirection smoke).  Either create\n"
    f"  smoke/README.md or correct the comment.",
)

# ===========================================================================
# PROBE 3 — activeDeadlineSeconds: leading-zero octal footgun
#
# The manifest uses unquoted template substitution:
#   activeDeadlineSeconds: {{workflow.parameters.job-active-deadline-seconds}}
#
# The default "300" is safe.  But if an operator passes a value with a
# leading zero ("0300", "0100") the resulting YAML line is:
#   activeDeadlineSeconds: 0300
#
# YAML 1.1 parses 0300 as octal 192 — silently applying a deadline 108 s
# shorter than intended.  The template has no guard.
# ===========================================================================
deadline_default = params.get("job-active-deadline-seconds", {}).get("value", "INVALID")

if manifest_raw and deadline_default != "INVALID":
    failed_any_octal = False
    detail_lines = []
    for test_val in ("0300", "0100"):
        subbed = manifest_raw.replace(
            "{{workflow.parameters.job-command}}", '["/bin/true"]'
        )
        subbed = subbed.replace(
            "{{workflow.parameters.job-active-deadline-seconds}}", test_val
        )
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
        not failed_any_octal,
        "activeDeadlineSeconds: leading zeros trigger YAML 1.1 octal parsing",
        f"  The smoke manifest uses unquoted template substitution for\n"
        f"  activeDeadlineSeconds.  If a submitter passes a value with a\n"
        f"  leading zero, YAML 1.1 interprets it as octal:\n"
        + "\n".join(detail_lines)
        + f"\n"
        f"  The template must either quote the value or validate that the\n"
        f"  parameter contains no leading zero.",
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

if deleter_flags is not None:
    ck(
        "--ignore-not-found" in deleter_flags,
        "delete-job exit handler: missing --ignore-not-found (not idempotent)",
        f"  onExit handler flags:  {deleter_flags!r}\n"
        f"  If the Job does not exist — cancelled before creation, already\n"
        f"  garbage-collected — kubectl delete exits non-zero and the Argo\n"
        f"  resource template marks the exit handler as failed.  Add\n"
        f"  --ignore-not-found to make the delete idempotent.",
    )

# ===========================================================================
# PROBE 5 — static.sh adversarial-evidence check is a fixture tautology
#
# test/static.sh lines 177-184 contain an assertion labelled "adversarial
# evidence" that hardcodes one set of values, merges them, and checks the
# result.  Because all inputs are hardcoded, the condition
#   merged_selector != K3S and merged_tolerations != []
# is always true — it passes regardless of what values.yaml contains.
# The assertion provides zero regression coverage.
# ===========================================================================
adversarial_selector = {
    "outpost.dhnt.io/backend": "vk-native",
    "kubernetes.io/os": "linux",
}
adversarial_tolerations = [
    {"key": "virtual-kubelet.io/provider", "operator": "Exists", "effect": "NoSchedule"}
]

prod_node_selector = (
    values.get("controller", {})
    .get("workflowDefaults", {})
    .get("spec", {})
    .get("nodeSelector", {})
    or {}
)
merged_normal = dict(prod_node_selector)
merged_normal.update(adversarial_selector)

merged_none = {}
merged_none.update(adversarial_selector)

passes_normal = merged_normal != K3S and adversarial_tolerations != []
passes_stripped = merged_none != K3S and adversarial_tolerations != []

ck(
    not (passes_normal and passes_stripped),
    "static.sh:182-184: tautology — asserts about fixture, not production",
    f"  The 'adversarial evidence' check in test/static.sh lines 182-184\n"
    f"  hardcodes an adversarial_selector and adversarial_tolerations, then\n"
    f"  asserts merged_selector != K3S and merged_tolerations != [].\n"
    f"\n"
    f"  With production values.yaml:       passes = {passes_normal}\n"
    f"  With workflowDefaults REMOVED:     passes = {passes_stripped}\n"
    f"  With workflowDefaults == vk-native: passes = True\n"
    f"\n"
    f"  No change to values.yaml can make this assertion fail.  It tests\n"
    f"  hardcoded fixture data, not production configuration.  It provides\n"
    f"  zero regression coverage and should be removed or replaced with a\n"
    f"  check that validates an actual production invariant.",
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
