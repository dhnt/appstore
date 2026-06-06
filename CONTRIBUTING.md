# Contributing to dhnt/appstore

## App PR checklist

For a new app under `apps/<id>/`:

- [ ] Lowercase kebab-case directory name. Mirrors the upstream Helm
      chart name where possible.
- [ ] `app.yaml` (schema below) with a stable `metadata.id` matching
      the directory name.
- [ ] `values.yaml` — default Helm values. Override-friendly:
      include only what cloudbox cares about diverging from the
      upstream chart's defaults. Empty `values.yaml` is fine.
- [ ] `icon.svg` — 64×64 viewBox, monochrome preferred. Inline only
      (no external href). Will be base64-embedded into the API.
- [ ] `README.md` — operator-facing description. First paragraph
      shown in the catalog grid; full content shown on app detail.
      Must include `## License` (one-line link to upstream license).
- [ ] `test/e2e.sh` — install → smoke → uninstall against any cluster
      with `kubectl`+`helm`+`curl`+`jq`. Exits 0 on pass. **Required
      for any app that sets `metadata.featured: true`**; recommended
      for all others.
- [ ] `test/perf.sh` — drives the app's bottleneck and writes
      `test/stats.json` (schema below). **Required for any app that
      sets `metadata.featured: true`**.
- [ ] README "## Tested performance" section — a small table of
      headline metrics, with values matching `test/stats.json`.
      Numbers may say _not yet measured_ until the first run is
      published, but the section + reproduction command must exist.
- [ ] README "## Reproducing these numbers" section — the exact
      bash one-liner a user runs to re-execute `e2e.sh` + `perf.sh`.
      No cloudbox-specific tooling — the test must run against any
      cluster where the user can helm-install.

## `app.yaml` schema

```yaml
apiVersion: appstore.dhnt.io/v1
kind: AppEntry
metadata:
  id: postgres                # matches directory name
  name: PostgreSQL            # display name
  version: "16.4"             # canonical version (display only)
  categories: [database, sql]
  tags: [storage, oltp, popular]
  maintainers:
    - email: ops@example.com
  description: >
    Single-line summary shown in the catalog grid.
  homepage: https://postgresql.org
  featured: false             # true → SPA renders this app in the Featured row at the top
  visibility: public          # public (default) | members | private — gates who can install
  members:                    # consulted ONLY when visibility=members
    - alice@example.com       # comma-list of emails; maintainers are always allowed
spec:
  chart:
    repo: https://charts.bitnami.com/bitnami
    name: postgresql
    version: "16.4.6"         # exact semver pin
  targetNamespace: "{{.UserNamespace}}"   # template var; only {{.UserNamespace}} allowed
  rbac:
    clusterScoped: false       # if true, gated to cloudbox-admin scope
  defaultValuesFile: values.yaml
```

Validation rules cloudbox enforces:

- `metadata.id` ≤ 63 characters, `[a-z0-9-]+`. Matches DNS label form.
- `spec.chart.version` MUST be exact semver. Loose semver (`^16`,
  `~16.4`) is rejected — repeatable installs depend on pin.
- `spec.targetNamespace` template vocabulary: only `{{.UserNamespace}}`
  is supported. Anything else fails the parser.
- `spec.rbac.clusterScoped: true` requires reviewer approval. Apps
  needing CRDs typically belong in `builtin/` instead.
- `metadata.visibility` ∈ `{public, members, private}` (omit to
  default to `public`). Tiers:
  - `public` — any cloudbox-authenticated user can install. Most
    catalog entries are this.
  - `members` — only `metadata.maintainers` OR addresses in
    `metadata.members` can install. The catalog still LISTS the
    entry to non-members (so they can request access from the
    maintainer); the install handler 403s with a "members-only"
    message.
  - `private` — only `metadata.maintainers` can install AND only
    they see the entry in the catalog at all. A direct lookup of
    the appid by anyone else returns 404 (so existence isn't
    confirmed). Use this for the closed-source-app-for-yourself
    pattern.

## `test/stats.json` schema

`test/perf.sh` writes one file: `test/stats.json`. The schema is
small and deliberately uniform across apps so the catalog-level
`STATS.md` table can render any of them.

```json
{
  "app": "qdrant",
  "chart": "qdrant/qdrant-1.13.0",
  "test_commit": "<git sha of dhnt/appstore at the time the perf ran>",
  "date": "2026-05-31",
  "cluster": {
    "kubelet": "v1.31.4+k3s1",
    "node_capacity": "8/32Gi"
  },
  "config": { "<app-specific knobs that drove the bench>": "..." },
  "results": { "<headline metric>": 12.3, "<secondary metric>": 4.5 }
}
```

The `results` object's keys vary per app — pick the metrics that
match the app's bottleneck (latency for query engines, throughput
for queues, etc.). Document them in the app's README "Tested
performance" table.

Reproducibility rules:

- Tests must work against any cluster (k3s, kind, EKS, DKS).
  No cloudbox-specific dependencies.
- Pin the chart version in the test to the same string as
  `app.yaml`'s `spec.chart.version`. Drift here is a bug.
- Random seeds (where used) must be fixed so two runs on
  identical hardware return identical results.

## Builtin PR checklist

For a new bundle under `builtin/<name>/`:

- [ ] Lowercase kebab-case directory name (becomes the bundle name).
- [ ] Single file `install.yaml` containing multi-doc YAML manifests
      (CRDs, RBAC, Deployments, etc.). SSA'd as cluster-admin.
- [ ] Comments at the top of `install.yaml` explaining purpose,
      upstream source, pinned version, and operator prereqs.

## Test before PR

```
# From the dhnt umbrella, with cloudbox running locally:
APPSTORE_PATH=$(pwd) ./script/test-stack-yc.sh up
# Verify the new app appears in cloudbox SPA → Cluster → Apps.
```

## Review SLA

Maintainers review within 1 week. Trivial bumps (chart version) may
land same-day; new apps wait for code review + smoke test.

## License

Apps in this catalog point at upstream charts — the catalog itself
does NOT redistribute chart contents. Per-app licensing is whatever
the upstream chart declares; check before contributing an app whose
upstream isn't OSS-licensed.
