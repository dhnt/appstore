# Redis

Open-source in-memory data store, used as a cache, message broker,
session backing, or pub/sub fan-out.

Installs the [Bitnami Redis chart](https://github.com/bitnami/charts/tree/main/bitnami/redis)
in **standalone** mode (1 master, no replicas) — appropriate for
per-user namespace footprint. For replication / Sentinel, override
`architecture: replication` in the install dialog.

## Connection

```
host: redis-<release-suffix>-master.user-<hash>.svc.cluster.local
port: 6379
auth: kubectl get secret redis-<suffix> -o jsonpath='{.data.redis-password}' | base64 -d
```
