#!/usr/bin/env python3
"""Offline regression checks for authenticated artifact repository resolution."""

import copy
import pathlib
import sys

import yaml

APP = pathlib.Path(__file__).resolve().parents[1]
repository_docs = list(yaml.safe_load_all((APP / "artifacts/seaweedfs.yaml").read_text()))
alias_doc = next((doc for doc in repository_docs if doc.get("kind") == "Service"), None)
repository_doc = next((doc for doc in repository_docs if doc.get("kind") == "ConfigMap"), None)
dispatcher = yaml.safe_load((APP / "dispatch/mixed-dks.yaml").read_text())
values = yaml.safe_load((APP / "values.yaml").read_text())
failures = []


def resolve(doc, workflow):
    """Model Argo's explicit ConfigMap/key resolution boundary."""
    ref = workflow.get("spec", {}).get("artifactRepositoryRef") or {}
    if doc is None or doc.get("kind") != "ConfigMap":
        raise ValueError("artifact repository ConfigMap is missing")
    if doc.get("metadata", {}).get("name") != ref.get("configMap"):
        raise ValueError("artifact repository ConfigMap does not match")
    key = ref.get("key")
    raw = (doc.get("data") or {}).get(key)
    if not raw:
        raise ValueError("artifact repository key is missing")
    return yaml.safe_load(raw)


try:
    repository = resolve(repository_doc, dispatcher)
except (ValueError, yaml.YAMLError) as error:
    failures.append(f"valid repository contract did not resolve: {error}")
    repository = {}

s3 = repository.get("s3") or {}
expected = {
    "endpoint": "seaweedfs-s3:8333",
    "bucket": "argo-artifacts",
    "region": "us-east-1",
    "insecure": True,
    "keyFormat": "artifacts/{{workflow.namespace}}/{{workflow.uid}}/{{pod.name}}",
    "accessKeySecret": {"name": "argo-artifacts-s3", "key": "accesskey"},
    "secretKeySecret": {"name": "argo-artifacts-s3", "key": "secretkey"},
}
if s3 != expected:
    failures.append(f"SeaweedFS repository must equal bounded contract: {s3!r}")

if repository_doc.get("metadata", {}).get("annotations", {}).get(
    "workflows.argoproj.io/default-artifact-repository"
) != "seaweedfs-v1":
    failures.append("default repository annotation must select seaweedfs-v1")

if not alias_doc or alias_doc.get("spec") != {
    "type": "ExternalName",
    "externalName": "seaweedfs-s3.seaweedfs-system.svc.cluster.local",
}:
    failures.append("single-label SeaweedFS path-style DNS alias is missing or mutable")

extra_objects = {
    (doc.get("kind"), (doc.get("metadata") or {}).get("name")): doc
    for doc in values.get("extraObjects", [])
}
chart_alias = extra_objects.get(("Service", "seaweedfs-s3"))
chart_repository_doc = extra_objects.get(("ConfigMap", "artifact-repositories"))
if not chart_alias or chart_alias.get("spec") != alias_doc.get("spec"):
    failures.append("chart-installed SeaweedFS alias drifted from standalone contract")
if not chart_repository_doc:
    failures.append("chart does not install the namespaced artifact repository contract")
else:
    chart_raw = (chart_repository_doc.get("data") or {}).get("seaweedfs-v1", "")
    for token in ("workflow.namespace", "workflow.uid", "pod.name"):
        chart_raw = chart_raw.replace('{{ "{{' + token + '}}" }}', "{{" + token + "}}")
    try:
        chart_repository = yaml.safe_load(chart_raw)
    except yaml.YAMLError as error:
        failures.append(f"chart artifact repository is not valid YAML: {error}")
    else:
        if chart_repository != repository:
            failures.append("chart-installed artifact repository drifted from standalone contract")
    if chart_repository_doc.get("metadata", {}).get("annotations") != repository_doc.get(
        "metadata", {}
    ).get("annotations"):
        failures.append("chart-installed default repository selection drifted")

for name, mutation in (
    ("missing ConfigMap", lambda: None),
    (
        "missing repository key",
        lambda: {
            **copy.deepcopy(repository_doc),
            "data": {},
        },
    ),
):
    try:
        resolve(mutation(), dispatcher)
    except ValueError:
        pass
    else:
        failures.append(f"{name} did not fail closed")

serialized = (APP / "artifacts/seaweedfs.yaml").read_text().lower()
for forbidden in ("aws_access_key_id", "aws_secret_access_key", "stringdata:"):
    if forbidden in serialized:
        failures.append(f"repository manifest contains forbidden credential field {forbidden!r}")

if failures:
    print("FAIL: " + "; ".join(failures), file=sys.stderr)
    sys.exit(1)
print("PASS — authenticated artifact repository resolves and missing repository fails closed")
