# Radar

Radar is an experimental, local-first Kubernetes UI from [Skyhook](https://github.com/skyhook-io/radar). It provides topology, resource, Helm, GitOps, traffic, and audit views in a single web application. It complements the cluster-admin Headlamp builtin; this catalog entry does not replace Headlamp.

The chart is installed into the caller's user namespace, but its upstream chart creates a read-only ClusterRole and ClusterRoleBinding because Radar inventories cluster-scoped resources such as nodes, namespaces, persistent volumes, and storage classes. Proxy authentication is enabled by default and requests without `X-Forwarded-User` are rejected. MCP is deliberately disabled; enable it only after reviewing the identity proxy and RBAC policy for the target cluster. The generic app-store route does not promise a preserved URL prefix, so `basePath` remains empty by default.

## License

Radar is Apache-2.0 licensed: [upstream LICENSE](https://github.com/skyhook-io/radar/blob/main/LICENSE).

## Tested performance

Not yet measured. The catalog entry is experimental and should be smoke-tested on a development cluster before wider use.

## Reproducing a smoke test

```bash
APPSTORE_PATH=$(pwd) ./test/e2e.sh
```

The test requires a Kubernetes cluster, Helm, `kubectl`, `curl`, and `jq`.
