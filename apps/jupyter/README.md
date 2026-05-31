# Jupyter Notebook

Single-user JupyterLab environment with scipy, pandas, pytorch, JAX,
TensorFlow preinstalled via the `jupyter/scipy-notebook` image.

Installed via the [JupyterHub Helm chart](https://github.com/jupyterhub/zero-to-jupyterhub-k8s)
in single-user mode (no per-user authenticator; relies on cloudbox
SSO at the proxy layer). 10 GiB persistent home directory.

## After install

Reach the notebook UI from the cloudbox SPA via the cluster service
proxy:

```
https://ai.dhnt.io/cluster/svc/<user-ns>/proxy-public/
```

Or look up the Service name via `kubectl get svc -n user-<hash>`.

## GPU workloads

This chart's `singleuser.image` is CPU-only by default. To use GPUs,
override `singleuser.image.name=quay.io/jupyter/pytorch-notebook` +
add `extraResource.limits.nvidia.com/gpu=1` at install time. Requires
the `gpu-device-plugin` bundle installed on the cluster + an outpost
with the host-OS NVIDIA toolkit (see outpost/docs/cluster-gpu.md).

## Tested performance

| Workload | Metric | Result |
|---|---|---|
| install → hub+proxy Ready | install time | _not yet measured_ |
| GET / via proxy-public | HTTP status | _not yet measured_ |
| 10 GiB user home PVC bind | bound | _not yet measured_ |

Smoke does NOT spawn a singleuser pod — that requires login state.
It only verifies the hub + proxy come up and the public endpoint
responds.

## Reproducing these numbers

```
git clone https://github.com/dhnt/appstore
cd appstore/apps/jupyter/test
export KUBECONFIG=~/.kube/config
./e2e.sh
```

## License

BSD 3-Clause — https://github.com/jupyter/notebook/blob/main/LICENSE
