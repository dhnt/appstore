#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../app.yaml"
VALUES="$HERE/../values.yaml"

python3 - "$APP" "$VALUES" <<'PY'
import sys
try:
    import yaml
except ImportError:
    raise SystemExit("static radar check requires python3 + PyYAML")

app = yaml.safe_load(open(sys.argv[1]))
values = yaml.safe_load(open(sys.argv[2]))
assert app["metadata"]["id"] == "radar"
assert app["spec"]["chart"] == {
    "repo": "https://skyhook-io.github.io/helm-charts",
    "name": "radar",
    "version": "1.9.2",
}
assert app["spec"]["rbac"]["clusterScoped"] is True
assert values["auth"]["mode"] == "proxy"
assert values["mcp"]["enabled"] is False
assert values["basePath"] == ""
assert values["rbac"]["helm"] is False
assert values["rbac"]["secrets"] is False
print("radar static catalog/security checks: PASS")
PY
