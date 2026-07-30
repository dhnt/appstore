#!/usr/bin/env python3
"""Offline contract and adversarial checks for dispatch/mixed-dks.yaml."""
import copy
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "dispatch/mixed-dks.yaml").read_text()
README = (ROOT / "README.md").read_text()
doc = yaml.safe_load(SOURCE)


def expression_backslashes(source):
    return [line for line in source.splitlines() if "{{=" in line and "\\" in line]


def errors(value):
    out = []
    spec = value.get("spec", {})
    if spec.get("artifactRepositoryRef") != {
        "configMap": "artifact-repositories",
        "key": "seaweedfs-v1",
    }:
        out.append("artifact repository is not an explicit namespaced fail-closed reference")
    if spec.get("nodeSelector") != {
        "outpost.dhnt.io/backend": "k3s",
        "kubernetes.io/os": "linux",
    } or spec.get("tolerations") != []:
        out.append("Argo pods are not hard-placed on real Linux k3s")
    params = {p["name"]: p for p in spec.get("arguments", {}).get("parameters", [])}
    for name in (
        "k3s-image", "k3s-command", "job-command", "native-artifact-url",
        "native-artifact-sha256", "native-artifact-path", "target-host",
        "target-node", "result-validator-image", "expected-result-name",
        "expected-result-kind", "expected-result-sha256",
    ):
        if name not in params or "value" in params.get(name, {}):
            out.append(f"required parameter {name} is absent or defaulted")
    templates = {t["name"]: t for t in spec.get("templates", [])}
    k3s_template = templates.get("k3s-phase", {})
    k3s = k3s_template.get("container", {})
    image_expr = str(k3s.get("image", ""))
    if "@sha256:[0-9a-f]{64}" not in image_expr or "? workflow.parameters['k3s-image'] : ''" not in image_expr:
        out.append("k3s image lacks immutable-digest fail-closed guard")
    patch = k3s_template.get("podSpecPatch", "")
    if ("command: {{=sprig.regexMatch(" not in patch
            or "workflow.parameters['k3s-command'] : 'INVALID'}}" not in patch):
        out.append("k3s argv lacks direct-exec fail-closed guard")
    if "/bin/sh" in patch or k3s.get("command") or k3s.get("args"):
        out.append("k3s workload is reinterpreted by a shell")
    resource = templates.get("create-watch-job", {}).get("resource", {})
    if not resource.get("successCondition") or not resource.get("failureCondition"):
        out.append("native Job status is not deterministically propagated")
    raw = resource.get("manifest", "")
    rendered = raw.replace("{{workflow.parameters.job-command}}", '["tool"]')
    rendered = re.sub(r"\{\{=.*\}\}", "PARAM", rendered)
    rendered = re.sub(r"\{\{[^}]*\}\}", "PARAM", rendered)
    job = yaml.safe_load(rendered)
    pod = job["spec"]["template"]["spec"]
    selector = pod.get("nodeSelector", {})
    if selector.get("outpost.dhnt.io/backend") != "vk-native" or set(selector) != {
        "outpost.dhnt.io/backend", "outpost.dhnt.io/host",
        "kubernetes.io/hostname", "kubernetes.io/os", "kubernetes.io/arch",
    }:
        out.append("native payload placement is not exact backend+host+os+arch")
    containers = pod.get("containers", [])
    if len(containers) != 1 or containers[0].get("image") != "dhnt.io/native-process":
        out.append("native payload does not use exactly one marker container")
    annotations = job["spec"]["template"]["metadata"].get("annotations", {})
    if set(annotations) != {
        "outpost.dhnt.io/native-artifact-url",
        "outpost.dhnt.io/native-artifact-sha256",
        "outpost.dhnt.io/native-artifact-path",
        "outpost.dhnt.io/termination-log-tail",
    }:
        out.append("verified native artifact tuple is incomplete")
    for key, value in annotations.items():
        if key == "outpost.dhnt.io/termination-log-tail":
            if value != "true":
                out.append("native result channel is not explicitly bounded/opted in")
        elif value != "PARAM":
            out.append(f"native annotation {key} lacks expression guard")
    if pod.get("automountServiceAccountToken") is not False or pod.get("volumes"):
        out.append("native payload admits projected credentials or volumes")
    for env in containers[0].get("env", []):
        if "valueFrom" in env or any(word in env.get("name", "").lower()
                                    for word in ("secret", "token", "password", "key")):
            out.append("native payload contains credential-bearing env")
    validator = templates.get("validate-native-result", {}).get("container", {})
    validator_image = str(validator.get("image", ""))
    if ("@sha256:[0-9a-f]{64}" not in validator_image or
            "? workflow.parameters['result-validator-image'] : ''" not in validator_image):
        out.append("native result validator image is not immutable/fail-closed")
    if validator.get("command") != ["bashy", "-c"]:
        out.append("native result validator does not use the trusted Bashy verifier")
    validator_script = "\n".join(validator.get("args", []))
    for required in (
        "owner_uid", "job_uid", "spec.nodeName", "target-node",
        "dhnt verify-native-result", "--expect-name", "--expect-kind",
        "--expect-sha256", "--expect-node", "--expect-backend vk-native",
        "--artifact-output",
    ):
        if required not in validator_script:
            out.append(f"native result validator lacks {required!r} cross-check")
    outputs = templates.get("validate-native-result", {}).get("outputs", {})
    output_artifacts = outputs.get("artifacts", [])
    if len(output_artifacts) != 1 or output_artifacts[0].get("path") != \
            "/tmp/dhnt-native-result/artifact":
        out.append("verified native result is not exposed as one Argo artifact")
    return out


failures = errors(doc)
for required_doc in (
    "BASHY_BIN_CACHE",
    "$BASHY_BIN_CACHE/kubectl/<version>/kubectl",
    "runtime download",
):
    if required_doc not in README:
        failures.append(
            f"validator-image offline kubectl cache contract lacks {required_doc!r}"
        )
if expression_backslashes(SOURCE):
    failures.append("Argo expression source contains parser-sensitive backslash escapes")
if not expression_backslashes(
    "command: {{=sprig.regexMatch('^\\[x', workflow.parameters.x)}}"
):
    failures.append("backslash-expression adversarial regression is ineffective")

# Render-level negative cases: commands must be non-empty argv sequences.
k3s_template = next(t for t in doc["spec"]["templates"] if t["name"] == "k3s-phase")
patch = k3s_template["podSpecPatch"]
for command, valid in (
    ('["tool","test"]', True),
    ('["tool"]', True),
    ('"tool --flag"', False),
    ("[]", False),
    ("{not-json", False),
):
    try:
        argv_pattern = re.compile(r'^\s*\[\s*"[^"]+"(\s*,\s*"[^"]*")*\s*\]\s*$')
        guarded = command if argv_pattern.fullmatch(command) else "INVALID"
        rendered_patch = re.sub(r"command: \{\{=.*\}\}", f"command: {guarded}", patch)
        rendered = yaml.safe_load(rendered_patch)
        argv = rendered["containers"][0]["command"]
        got = isinstance(argv, list) and bool(argv) and all(isinstance(x, str) and x for x in argv)
    except (yaml.YAMLError, KeyError, TypeError):
        got = False
    if got != valid:
        failures.append(f"k3s-command validation mismatch for {command!r}")

image_pattern = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
for image, valid in (
    ("registry.example/tool@sha256:" + "a" * 64, True),
    ("registry.example/tool:latest", False),
    ("registry.example/tool@sha256:" + "A" * 64, False),
    ("", False),
):
    if bool(image_pattern.fullmatch(image)) != valid:
        failures.append(f"k3s-image guard mismatch for {image!r}")

sha_pattern = re.compile(r"^[0-9a-f]{64}$")
url_pattern = re.compile(
    r"^(https://[^\s]+|http://(127\.0\.0\.1|localhost)(:[0-9]+)?/[^\s]+)$"
)
path_pattern = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._/-]*$")
for value in ("", "abc", "A" * 64, "0" * 63):
    if sha_pattern.fullmatch(value):
        failures.append(f"invalid native digest accepted: {value!r}")
for value in ("", "http://example/tool.tgz", "https://bad url/tool.tgz"):
    if url_pattern.fullmatch(value):
        failures.append(f"invalid native URL accepted: {value!r}")
for value in (
    "https://artifacts.example/tool.tgz",
    "http://localhost/tool.tgz",
    "http://localhost:8080/releases/tool.tgz",
    "http://127.0.0.1:9090/tool.zip",
):
    if not url_pattern.fullmatch(value):
        failures.append(f"valid native URL rejected: {value!r}")
for value in (
    "http://127.0.0.2/tool.tgz",
    "http://localhost.evil/tool.tgz",
    "http://localhost",
    "http://127.0.0.1:bad/tool.tgz",
    "http://127.0.0.1/bad path/tool.tgz",
):
    if url_pattern.fullmatch(value):
        failures.append(f"unsafe loopback native URL accepted: {value!r}")
for value in ("", "/tool", "../tool", "bin/../tool", "bin/..", r"bin\\tool"):
    valid = bool(path_pattern.fullmatch(value)) and "../" not in value and not value.endswith("/..")
    if valid:
        failures.append(f"unsafe native path accepted: {value!r}")

mutations = {
    "missing artifact repository reference": lambda d: d["spec"].pop(
        "artifactRepositoryRef"
    ),
    "k3s fallback": lambda d: d["spec"].update(nodeSelector={}),
    "OCI-on-native": lambda d: next(t for t in d["spec"]["templates"]
                                    if t["name"] == "create-watch-job")["resource"].update(
                                        manifest=next(t for t in d["spec"]["templates"]
                                        if t["name"] == "create-watch-job")["resource"]["manifest"]
                                        .replace("dhnt.io/native-process", "ubuntu:latest")),
    "missing failure propagation": lambda d: next(
        t for t in d["spec"]["templates"] if t["name"] == "create-watch-job"
    )["resource"].pop("failureCondition"),
    "mutable k3s image": lambda d: next(
        t for t in d["spec"]["templates"] if t["name"] == "k3s-phase"
    )["container"].update(image="{{workflow.parameters.k3s-image}}"),
    "shell k3s command": lambda d: next(
        t for t in d["spec"]["templates"] if t["name"] == "k3s-phase"
    ).update(podSpecPatch='containers: [{name: main, command: ["/bin/sh","-c"]}]'),
    "missing native result verifier": lambda d: d["spec"]["templates"].remove(
        next(t for t in d["spec"]["templates"]
             if t["name"] == "validate-native-result")),
    "missing bounded result opt-in": lambda d: (
        lambda manifest: next(
            t for t in d["spec"]["templates"]
            if t["name"] == "create-watch-job"
        )["resource"].update(
            manifest=manifest.replace(
                'outpost.dhnt.io/termination-log-tail: "true"',
                'removed.example/termination-log-tail: "true"',
            )
        )
    )(next(t for t in d["spec"]["templates"]
           if t["name"] == "create-watch-job")["resource"]["manifest"]),
}
for name, mutate in mutations.items():
    candidate = copy.deepcopy(doc)
    mutate(candidate)
    if not errors(candidate):
        failures.append(f"adversarial mutation escaped: {name}")

if failures:
    print("FAIL: " + "; ".join(failures), file=sys.stderr)
    sys.exit(1)
print("PASS — mixed DKS dispatch static/adversarial contract")
