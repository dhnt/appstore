# karmada — DKS federation control plane (builtin)

Installs the [Karmada](https://github.com/karmada-io/karmada) multi-cluster
control plane on one DKS plane through the upstream **karmada-operator** and a
single `Karmada` custom resource. It is the control-plane half of dhnt's
peer-to-peer federation (`outpost cluster federation on` installs it;
`bashy dks federation …` drives it). Karmada is used **as is**: no source is
vendored and nothing upstream is forked.

- **Upstream:** <https://github.com/karmada-io/karmada> (CNCF)
- **Version:** **v1.19.0** — operator chart `karmada-operator` v1.19.0
  (appVersion v1.19.0), pinned by release-asset URL **and** sha256
  `1b1b7d7e9aa987fe69e1141bbd1cd3f2a4667b73c6cc8ad03f96294596215c69`
  in `install.yaml`; the Job fails closed on a digest mismatch.
- **Install scope:** cluster-admin singleton, namespace `karmada-system`.
  Triggered by `outpost bundle install karmada` or (standalone / satellite
  cloudbox builds only) `POST /api/cluster/install/karmada`.
- **Bump cadence:** pin move only through the dhnt design doc
  (`docs/dks-federation-karmada.md` §9); the operator and the `Karmada` CR
  tags move together.

## What the Job does

1. `curl` the pinned chart tarball from the v1.19.0 GitHub release and verify
   its sha256.
2. `helm upgrade --install karmada-operator` into `karmada-system`
   (`installCRDs=true`, `crds.keep=true`, operator image
   `docker.io/karmada/karmada-operator:v1.19.0`).
3. Wait for CRD `karmadas.operator.karmada.io` to be `Established` and the
   operator Deployment to roll out.
4. Apply `Karmada` `karmada-system/karmada`:
   `certSANs: [127.0.0.1, karmada-apiserver.karmada-system.svc]`,
   `serviceType: ClusterIP`, one replica per component, etcd data under the
   Outpost runtime's persisted storage path, component images
   pinned to the tags below.
5. `kubectl -n karmada-system wait --for=condition=Ready karmada/karmada --timeout=15m`.
6. Publish the full log as ConfigMap `karmada-system/install-log`.

## Post-install contract

| What | Where |
|---|---|
| Federation apiserver | Service `karmada-system/karmada-apiserver`, ClusterIP, port 5443 |
| Admin kubeconfig | Secret `karmada-system/karmada-admin-config`, key `karmada.config` (also `status.secretRef`) |
| Readiness | `Karmada` condition `Ready` |
| Host publication | outpost publishes the Service on `127.0.0.1:15443` (not part of this bundle) |

## Pinned images (linux, multi-arch amd64 + arm64)

| Image | amd64 sha256 | arm64 sha256 |
|---|---|---|
| `docker.io/karmada/karmada-operator:v1.19.0` | `99f7afe0cc2b042ce97bae50a34c8944fbd4df3134a0975e3e32e6e82b08f5dc` | `b9f2102bca20b17bee5c0b4fb8203e31c1902bc83b26ad3c30d697357e96b49b` |
| `docker.io/karmada/karmada-aggregated-apiserver:v1.19.0` | `e1095701d1a7ba1794f6cc4726d6f70d85b95b386194e7b00ae8313a594984ff` | `5ad006539b0e23ff348d2ddcda32f4155cd7c2833855ef5efb136c251a0f1ab0` |
| `docker.io/karmada/karmada-controller-manager:v1.19.0` | `54057d7854da386ff76f40274facc23c4154a3074b451ae38541726143b24f53` | `b7719bbfb667e13a52a368d56bcd167b0ed8bfc4e8b6582133503ac87bfcb622` |
| `docker.io/karmada/karmada-scheduler:v1.19.0` | `7bf08f7faafd00f3e658a15fd6bdd3c9625a79f9bcf1d2d0e7ca8b4d5d747e68` | `1251fce85ac45d9614f15973da759ee93fc993ecf8403b0f43f402540dac9176` |
| `docker.io/karmada/karmada-webhook:v1.19.0` | `6e00749d79c23f5fdb16cd24687e004fee75af92611ae1bb47ac67036c36f321` | `d7ec55047cbe339512ffeb9eeef705ccc568b41b574e19857d0feafac7e7e8bf` |
| `registry.k8s.io/kube-apiserver:v1.36.2` | `8822e615af23007c2ab4813c09dbf8aef4d209da49832250832aaeadcd4601d3` | `e82b75275d989a186fad4f894e4ada737abe9aed628edab8c49e78dee5d055e4` |
| `registry.k8s.io/kube-controller-manager:v1.36.2` | `7e996a8b8e9d6e8a59a6576c5f226772a85eeb1350fabf6d2b6e99caf43b39c8` | `427707f4efc9ed00b14e9d140821882cada7b0cb08f796edc4344b7521050dd5` |
| `registry.k8s.io/etcd:3.6.8-0` | `aa2b41e3f99c9a337b82f687875a63c5119e6d39bc43fc76b6c40a96f55cf391` | `82bf8bc50b9a953f8b477adb63f12637229d8044e85b21501a3c6a4be59afbb8` |

The member-side agent image (`docker.io/karmada/karmada-agent:v1.19.0`) is
pulled by `karmadactl register`, not by this bundle.

## Requirements and caveats

- Egress from the plane to `github.com` (chart tarball and the pinned v1.19.0
  Karmada CRD tarball), `docker.io` and `registry.k8s.io`. Air-gapped planes must
  mirror and set `spec.privateRegistry`.
- The single etcd replica uses a host path under the Outpost runtime's
  persisted `/var/lib/rancher/k3s/storage` volume. It survives runtime
  container recreation and stays on that one member node.
- Single replica everywhere: an MVP for peer ↔ peer federation. No HA.
- Expect roughly 1.5–2 GB of memory at rest on top of DKS (provisional until
  measured).
- The installer ServiceAccount + `cluster-admin` binding persist after the
  Job's TTL (same as `headlamp`); the install is idempotent and can be
  re-run.
- No Windows control-plane host (Karmada ships no Windows `karmadactl`).

## License

Karmada is licensed under the
[Apache License 2.0](https://github.com/karmada-io/karmada/blob/v1.19.0/LICENSE).
This bundle (`install.yaml`, this README) is part of `dhnt/appstore`, Apache-2.0.
