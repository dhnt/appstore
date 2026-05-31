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

## Tested performance

Redis serves as the **install-pipeline canary** for the catalog —
the simplest possible smoke for "did the chart install + PVC bind
+ secret mount work on this cluster". Performance numbers are
not the headline here; correctness is.

| Workload | Metric | Result |
|---|---|---|
| install → master Ready | install time | _not yet measured_ |
| PING / SET / GET roundtrip | smoke pass | _not yet measured_ |
| 4 GiB PVC bind | bound | _not yet measured_ |

## Reproducing these numbers

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/redis/test
export KUBECONFIG=~/.kube/config
./e2e.sh
```

`e2e.sh` is intentionally minimal — exercises only what every
other app in the catalog also exercises. If THIS fails on your
cluster, every other app will too; debug the cluster first.

## License

BSD 3-Clause (Redis OSS) — https://github.com/redis/redis/blob/unstable/LICENSE.txt
