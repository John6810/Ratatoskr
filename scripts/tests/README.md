# Deployment and recovery tests

Run from the repository root. Install the pinned Linux amd64 tools using
`bash scripts/tests/install-tools.sh /path/to/bin`, add that directory to `PATH`,
and install Python 3 with PyYAML, Docker, kubectl, and jq.

| Command | Coverage |
|---|---|
| `bash scripts/tests/validate.sh` | Regression tests, shell syntax, strict Helm lint, rendered Kubernetes and CRD schemas |
| `bash scripts/tests/compose-smoke.sh` | Compose startup, HTTP, repeat migrations, init cancellation |
| `bash scripts/tests/backup-restore-drill.sh` | Physical MariaDB backup, encrypted Restic storage, restore and retained originals |
| `bash scripts/tests/helm-lifecycle.sh` | Install, chart-version upgrade, stable keys/data, failed migration, recovery, external services |
| `bash scripts/tests/kustomize-smoke.sh` | Kustomize startup and APP_KEY bootstrap stability |
| `bash scripts/tests/rwx-migration.sh` | RWO→RWX copy, files across nodes, Pod replacement, retained-volume rollback |
| `bash scripts/tests/rwx-kind.sh` | Creates and deletes an isolated three-node Kind cluster, installs NFS CSI, runs both RWX suites |

Build the current application before runtime tests:

```bash
docker buildx build --load --platform linux/amd64 --provenance=false \
  -f docker/Dockerfile -t ratatoskr/unit3d:dev .
UNIT3D_TEST_IMAGE=ratatoskr/unit3d:dev bash scripts/tests/rwx-kind.sh
```

The standalone Kubernetes suites require an explicit `KUBECONFIG` and create
their own namespaces. The RWX suites also require `RWX_STORAGE_CLASS`. Setting
that variable for `helm-lifecycle.sh` enables two app/queue replicas, verifies
placement on different nodes, checks that a failed upgrade keeps the old app
replicas available, and exercises `helm rollback` before the recovery upgrade.

`rwx-kind.sh` uses the official NFS CSI chart 4.13.5 with a checked archive digest.
Its Ganesha server is a disposable test fixture inside a Kind node, with an
exported hostPath and no root squash. It is not a production NFS configuration.
The server stays on its original node. Clients use NFS 4.0 to avoid
[Ganesha issue #1385](https://github.com/nfs-ganesha/nfs-ganesha/issues/1385)
with directory delegations on Linux 6.19+; no host kernel parameter is changed.

For an explicit static-volume alternative:

```bash
STATIC_NFS=1 UNIT3D_TEST_IMAGE=ratatoskr/unit3d:dev \
  PVC_LOADER_IMAGE=ratatoskr/unit3d:dev bash scripts/tests/rwx-kind.sh
```

This uses precreated NFS PVs and exercises real network mounts, concurrent Pods,
and rollback, but does **not** certify CSI dynamic provisioning. Cached Docker
dependencies are imported into the new cluster when available. The same static
fixture can be used with the standalone suites on a `kind-ratatoskr-*` cluster
where `fixtures/nfs-server.yaml` is already installed. It is never selected
automatically after a CSI failure.

The migration fixture creates 132 files, including dotfiles, spaces, Unicode,
quotes, and a newline in a filename, plus a symlink and database sentinel. It
takes real private backups before calling the operational migration script.
Cleanup affects only the namespace created by that run and its volumes.
`KEEP_FAILED_NAMESPACE=1` retains a failed migration fixture for investigation.

The GitHub workflow is `.github/workflows/validate.yml`. Local execution does
not imply that GitHub Actions or the production CSI/CNI have been validated.
