#!/usr/bin/env python3
"""Offline contract and adversarial checks for dispatch/mixed-dks.yaml."""
import copy
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
doc = yaml.safe_load((ROOT / "dispatch/mixed-dks.yaml").read_text())


def errors(value):
    out = []
    spec = value.get("spec", {})
    if spec.get("nodeSelector") != {
        "outpost.dhnt.io/backend": "k3s",
        "kubernetes.io/os": "linux",
    } or spec.get("tolerations") != []:
        out.append("Argo pods are not hard-placed on real Linux k3s")
    params = {p["name"]: p for p in spec.get("arguments", {}).get("parameters", [])}
    for name in ("k3s-image", "k3s-command", "job-command", "native-artifact-url",
                 "native-artifact-sha256", "native-artifact-path", "target-host"):
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
        "kubernetes.io/os", "kubernetes.io/arch",
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
    }:
        out.append("verified native artifact tuple is incomplete")
    for key, value in annotations.items():
        if value != "PARAM":
            out.append(f"native annotation {key} lacks expression guard")
    if pod.get("automountServiceAccountToken") is not False or pod.get("volumes"):
        out.append("native payload admits projected credentials or volumes")
    for env in containers[0].get("env", []):
        if "valueFrom" in env or any(word in env.get("name", "").lower()
                                    for word in ("secret", "token", "password", "key")):
            out.append("native payload contains credential-bearing env")
    return out


failures = errors(doc)

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
url_pattern = re.compile(r"^https://[^\s]+$")
path_pattern = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._/-]*$")
for value in ("", "abc", "A" * 64, "0" * 63):
    if sha_pattern.fullmatch(value):
        failures.append(f"invalid native digest accepted: {value!r}")
for value in ("", "http://example/tool.tgz", "https://bad url/tool.tgz"):
    if url_pattern.fullmatch(value):
        failures.append(f"invalid native URL accepted: {value!r}")
for value in ("", "/tool", "../tool", "bin/../tool", "bin/..", r"bin\\tool"):
    valid = bool(path_pattern.fullmatch(value)) and "../" not in value and not value.endswith("/..")
    if valid:
        failures.append(f"unsafe native path accepted: {value!r}")

mutations = {
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
