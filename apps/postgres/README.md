# PostgreSQL

PostgreSQL is a powerful, open-source object-relational database
system with a strong reputation for reliability, feature robustness,
and performance.

This app installs the [Bitnami PostgreSQL chart](https://github.com/bitnami/charts/tree/main/bitnami/postgresql)
into your DKS namespace. Defaults match cloudbox's per-user quota
ceiling (8 GiB PVC, 1 CPU / 1 GiB memory limit).

## After install

```
$ kubectl get pods -n user-<hash>
NAME                       READY   STATUS    RESTARTS   AGE
postgres-a3b7e-postgresql-0   1/1   Running   0          1m
```

Connection string for in-cluster clients:

```
host: postgres-<release-suffix>-postgresql.user-<hash>.svc.cluster.local
port: 5432
user: postgres
password: <see Secret postgres-<suffix>-postgresql>
```

Retrieve the password:

```
kubectl get secret postgres-<suffix>-postgresql -n user-<hash> \
  -o jsonpath='{.data.postgres-password}' | base64 -d
```

## Resource defaults

- Storage: 8 GiB PVC (counts against your namespace's 100 GiB quota)
- CPU: 1 core limit, 100m request
- Memory: 1 GiB limit, 256 MiB request

Override at install time in the Cloudbox SPA's install dialog if
you need a heavier footprint.

## Tested performance

| Workload | Metric | Result |
|---|---|---|
| install → primary Ready | install time | _not yet measured_ |
| CREATE/INSERT/SELECT roundtrip | smoke pass | _not yet measured_ |
| 8 GiB PVC bind | bound | _not yet measured_ |

Postgres is the second-tier install canary — after redis passes,
this verifies that init-container + secret-mount + larger-PVC
paths also work.

## Reproducing these numbers

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/postgres/test
export KUBECONFIG=~/.kube/config
./e2e.sh
```

## License

PostgreSQL License (MIT-style) — https://www.postgresql.org/about/licence/
