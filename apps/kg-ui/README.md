# kg-ui

Monitor and explorer SPA for a running `kg` daemon — the personal
knowledge-grapher that ingests a user's digital activities into a
queryable graph and exposes it over MCP.

## What it is

A small Go reverse-proxy + embedded React/HTML SPA. Three pages:

- **/** — monitor: stats grid, recent ExtractionRuns, per-substage
  pipeline panel (in-flight / throughput / p50 / p99 / recent
  inputs+outputs), and the live event log via EventSource.
- **/explore.html** — explorer: search box, type filter chips,
  vis-network canvas, click-to-expand node detail.
- **/queue.html** — queue inspector: pool depth per subpool,
  ledger pending/running/done/failed counts, recent failures with
  last_error.

The UI does no ingestion itself: every request is either an asset
fetched from the embedded bundle, or a proxied `/api/*` /
`/events` request that lands on a running kg daemon configured via
`--daemon`.

## How it fits with cloudbox + outpost

kg-ui follows the split-deployment shape: a host-bound worker
scans and parses the user's filesystem, while a DKS-pod UI talks
back to that worker through cloudbox + outpost.

The `kg daemon` MUST run on the host where the filesystem it scans
lives — that's by design, the personal-KG point. When `kg-ui` is
installed via this app, it's a stateless pod that the user reaches
through `cloudbox /matrix/cluster/svc/<user-ns>/kg-ui/`. The SPA's
`<base href>` is rewritten per-request from `X-Forwarded-Prefix`,
so every `/api/*` URL it emits round-trips through the same
cloudbox prefix back to the kg-ui pod. The pod's reverse proxy
then forwards to its `--daemon` URL — typically another cloudbox
path like `/matrix/h/<host>/app/kg/` which exits via the matrix
tunnel onto the user's host where the daemon lives.

For this round-trip to work, the user's outpost must advertise
`kg` as one of its registered apps in `agent.json`:

```yaml
apps:
  - name: kg
    port: 1380       # whatever --api the daemon was started with
    require_login: true
```

## Configuration

Set `daemon.url` at install time. The default is empty and won't
reach anything from inside the pod.

```
daemon:
  url: https://<your-cloudbox>/matrix/h/<host>/app/kg
```

Other knobs (resources, replicas, ingress) match the chart's
`values.yaml` in the kg repo at `deploy/charts/kg-ui/values.yaml`.

## License

The kg-ui container image is built from the [kg
repository](https://github.com/qiangli/kg) — proprietary; the
catalog metadata in this directory is released under Apache 2.0
along with the rest of `dhnt/appstore`.
