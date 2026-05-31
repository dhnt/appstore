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
