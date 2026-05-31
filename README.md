# dhnt/appstore — DKS App Catalog

Public catalog of installable apps + cloudbox-shipped builtin bundles
for **DKS** (dhnt's managed Kubernetes service; see the `cloudbox`
component of the dhnt umbrella).

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
