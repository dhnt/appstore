# Hello Tessaro (appstore entry)

Reference "custom app on tessaro", installable into a user's DKS namespace.

- **Source + chart:** `github.com/qiangli/outpost` → `examples/hello-tessaro/`
  (app in `main.go` + `internal/tessaro/`; chart in `chart/`).
- **Guide:** `docs/custom-app-on-tessaro.md` (umbrella).

## Two install paths

1. **GitOps (working today)** — `examples/hello-tessaro/gitops/applicationset.yaml`
   gives you three isolated environments (`hello-tessaro-{dev,qa,prod}`) promoted
   by git. This is the recommended path and the one that exercises the dev/qa/prod
   model.
2. **One-click (this entry)** — installs a single instance into the caller's
   `{{.UserNamespace}}`. **Pending:** the chart must be published to the Helm repo
   named in `app.yaml` (`spec.chart.repo`); the chart source is in-repo under
   `examples/hello-tessaro/chart/`. Publish recipe is the same as the other
   first-party charts (kg-ui): push `chart/` to a `-charts` repo served over
   Pages, then bump `spec.chart.version` here.

## Post-install

Provide the per-env `sso_secret` (a Sealed Secret; set `ssoSecretName`) matching
the app's cloudbox tile, then reach the app at
`…/matrix/cluster/svc/<ns>/hello-tessaro/`.
