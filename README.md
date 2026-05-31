# dhnt/appstore — DKS App Catalog

Public catalog of installable apps + cloudbox-shipped builtin bundles
for **DKS** (dhnt's managed Kubernetes service; see the `cloudbox`
component of the dhnt umbrella).

**Live deployment**: <https://ai.dhnt.io/> — log in and browse
**Cluster → App Store** to install any of the apps below into your
per-user namespace with one click.

**Performance claims**: each app's headline numbers + the exact
benchmark commands are published in [`STATS.md`](./STATS.md) — every
result is reproducible from `apps/<id>/test/perf.sh`.

## License

**This catalog repo** (`dhnt/appstore`) is open source — see
`LICENSE` (Apache 2.0). The metadata, READMEs, icons, and default
values you contribute here are released under the same.

**The apps the catalog lists are NOT** — each app entry is a thin
pointer to an upstream Helm chart (`spec.chart.repo` +
`spec.chart.version`). When a user clicks Install in cloudbox, the
upstream chart is fetched at install time and the upstream's own
license governs how the resulting workload may be used.

Curation policy: cloudbox prefers OSI-approved licenses (MIT,
Apache 2.0, BSD, MPL, etc.) for catalog inclusion. Apps with custom
"open-but-restricted" licenses (e.g. preserve-branding clauses,
non-commercial gates, source-available shells around closed cores)
land in the catalog only when the restrictions are compatible with
self-hosted-by-end-user usage and are clearly documented in the
app's `README.md`. Apps that require a commercial license for the
substantive functionality (i.e. OSS as a teaser) are out of scope.

If you're contributing an app: include a one-line `## License`
section in `apps/<id>/README.md` linking to the upstream license.
Maintainers will not merge an app without it.

## Layout

```
appstore/
├── README.md           # this file
├── CONTRIBUTING.md     # how to PR a new app
├── categories.yaml     # top-level taxonomy
├── apps/               # per-user Helm-installable apps
│   └── <id>/
│       ├── app.yaml    # cloudbox metadata + chart pointer
│       ├── values.yaml # default Helm values
│       ├── icon.svg    # 64×64 icon
│       └── README.md   # long description (rendered in SPA)
└── builtin/            # cluster-admin singleton bundles
    └── <name>/
        └── install.yaml  # SSA-applied manifest (CRDs, RBAC, Jobs)
```

Two folders, same catalog format-wise (each app/builtin is a
directory with a manifest). They differ in **how cloudbox installs
them**:

- `apps/` → per-user `helm install` into the caller's `user-<hash>`
  namespace. Triggered from cloudbox SPA's "Install" button.
- `builtin/` → cluster-admin SSA install into a fixed namespace.
  Triggered via `POST /api/cluster/install/<name>` (admin-only).

## Adding an app

See `CONTRIBUTING.md` for the full PR recipe. Quick version:

1. Fork this repo
2. Create `apps/<id>/{app.yaml, values.yaml, icon.svg, README.md}`
3. Verify schema with `script/lint.sh` (TODO)
4. Submit PR

PRs are reviewed by the dhnt maintainers. After merge, cloudbox
deployments pick up the new app within ~5 minutes (background sync
cadence) — no cloudbox redeploy needed.

## Adding a builtin

Same shape, in `builtin/<name>/install.yaml`. Builtin manifests are
SSA'd at cluster-admin tier with field-manager `cloudbox-bundle:<name>`,
so they may declare cluster-scoped resources (CRDs, ClusterRoles, etc.).

Reserve builtins for **infrastructure** components (storage classes,
ingress controllers, GPU device plugins, ML platforms). Workloads
that an end-user wants to spin up on demand belong in `apps/`.
