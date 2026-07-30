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
    for name in ("k3s-image", "k3s-script", "job-command", "native-artifact-url",
                 "native-artifact-sha256", "native-artifact-path", "target-host"):
        if name not in params or "value" in params.get(name, {}):
            out.append(f"required parameter {name} is absent or defaulted")
    templates = {t["name"]: t for t in spec.get("templates", [])}
    k3s = templates.get("k3s-phase", {}).get("container", {})
    if k3s.get("image") != "{{workflow.parameters.k3s-image}}":
        out.append("k3s OCI image is not isolated to the k3s phase")
    resource = templates.get("create-watch-job", {}).get("resource", {})
    if not resource.get("successCondition") or not resource.get("failureCondition"):
        out.append("native Job status is not deterministically propagated")
    raw = resource.get("manifest", "")
    rendered = raw.replace("{{workflow.parameters.job-command}}", '["tool"]')
    rendered = re.sub(r"\{\{=[^}]*\}\}", "300", rendered)
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
    if pod.get("automountServiceAccountToken") is not False or pod.get("volumes"):
        out.append("native payload admits projected credentials or volumes")
    for env in containers[0].get("env", []):
        if "valueFrom" in env or any(word in env.get("name", "").lower()
                                    for word in ("secret", "token", "password", "key")):
            out.append("native payload contains credential-bearing env")
    return out


failures = errors(doc)
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
