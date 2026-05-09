# Smoke tests

Real-cluster validation scripts. Run BEFORE tagging a release to catch
what `helm template` and `kubeconform` cannot — image pull, PVC binding,
init Job ordering, runtime probes, end-to-end HTTP.

---

## helm-chart-smoke.sh

End-to-end install of the ratatoskr Helm chart against a real Kubernetes
cluster, with progressive verification and unconditional teardown.

### Scope

- **In scope**: chart install, image pull, PVC binding, migrate Job
  ordering vs workload Deployments, pod readiness probes, intra-cluster
  service discovery (Redis auth, MeiliSearch health), HTTP probe through
  the `unit3d-app` Service.
- **Out of scope**: multi-replica HA, ingress controllers, S3 routing,
  KEDA scaling. Those are overlay-specific and tested separately.

### Prerequisites

On the target node (typically a control-plane or worker node with full
kubeconfig access):

- `kubectl`, `helm` (>= 3.14), `openssl`, `curl` installed and on `PATH`
- A working kubeconfig pointing at the target cluster
- A storage class that provisions volumes (`csi-rawfile` by default; see
  `STORAGE_CLASS` env var)
- ~25 GB of free PVC capacity (mariadb 10Gi + redis 1Gi + meilisearch
  5Gi + unit3d-storage 5Gi, plus headroom)
- The target namespace must NOT already exist (script aborts at
  preflight 15 to avoid clobbering an operator's existing install)

### Required env vars

None. All defaults work for a kame-style cluster with `csi-rawfile`.

### Optional env vars

| Var | Default | Effect |
|---|---|---|
| `NAMESPACE` | `ratatoskr-test` | Target K8s namespace |
| `RELEASE` | `ratatoskr` | Helm release name |
| `CHART_PATH` | `./helm/ratatoskr` | Path to the chart (relative to CWD) |
| `STORAGE_CLASS` | `csi-rawfile` | StorageClass for all PVCs |
| `INSTALL_TIMEOUT` | `10m` | `helm install --timeout` |
| `APP_URL` | `http://localhost:8080` | UNIT3D `APP_URL` env |
| `KEEP_NAMESPACE` | `0` | Set `1` to skip cleanup (debug / inspection) |
| `APP_KEY` | auto-generated | Laravel `APP_KEY` (`base64:…` form) |
| `MARIADB_ROOT_PW` | auto-generated | MariaDB root password |
| `MARIADB_USER_PW` | auto-generated | MariaDB unit3d user password |
| `REDIS_PW` | auto-generated | Redis AUTH password |
| `MEILI_KEY` | auto-generated | MeiliSearch master key (32 bytes) |

Auto-generated secrets are produced via `openssl rand` on each run and
SHA-256-hashed in the log (the actual values are never written to disk
beyond Helm's release storage in the target namespace).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | PASS — all 9 verifications green |
| `1` | Generic error (unexpected failure) |
| `10` | kubectl cannot reach the cluster API server |
| `11` | Storage class not found |
| `12` | K8s server version below 1.30 |
| `13` | Required tool missing (`kubectl`/`helm`/`openssl`/`curl`) or `helm` < 3.14 |
| `14` | Chart path missing or `helm lint` failed |
| `15` | Target namespace already exists |
| `20` | `kubectl create namespace` failed |
| `22` | `helm install` failed or timed out |
| `30 + N` | `N` verification checks failed (e.g. `33` = 3 checks failed) |
| `40` | Cleanup phase failed (`helm uninstall` non-zero or namespace delete timeout) |

### Usage

Run from a node with cluster access. Output is captured by piping
through `tee` per the standard ratatoskr operator workflow:

```bash
# 1. Get the chart onto the node (one of):
#
#    Option A — clone the repo:
#      git clone https://github.com/John6810/Ratatoskr.git
#      cd Ratatoskr
#
#    Option B — scp from operator workstation:
#      scp -r helm/ratatoskr scripts/smoke kame01:~/ratatoskr-smoke/
#      ssh kame01
#      cd ~/ratatoskr-smoke

# 2. Run the smoke test, capture output:
LOG=/tmp/ratatoskr-smoke-$(date +%Y%m%d-%H%M%S).log
sh scripts/smoke/helm-chart-smoke.sh 2>&1 | tee "$LOG"

# 3. Check the final marker line:
grep ^SMOKE_RESULT= "$LOG"
# Expect: SMOKE_RESULT=PASS

# 4. (Operator-side, after run) scp the log back for review:
#      scp kame01:"$LOG" ./
```

Common operator overrides:

```bash
# Different storage class (e.g. local-path on k3s):
STORAGE_CLASS=local-path sh scripts/smoke/helm-chart-smoke.sh

# Keep the namespace for inspection / kubectl exec / log dump:
KEEP_NAMESPACE=1 sh scripts/smoke/helm-chart-smoke.sh

# Reuse a known-good APP_KEY (e.g. across consecutive runs to compare):
APP_KEY="base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" \
  sh scripts/smoke/helm-chart-smoke.sh
```

### Failure recovery

The cleanup trap runs unconditionally on every exit, so a failed run
leaves no orphan resources by default.

- **Aborted during preflight (exits 10-15)**: nothing was installed.
  Fix the failing check and re-run.
- **Aborted during install (exit 22)**: the script logs the failing
  pod list + recent events to stderr before exiting; cleanup still
  runs. Inspect the captured log for `ImagePullBackOff` / `Pending` /
  `CrashLoopBackOff` patterns.
- **Aborted during verify (exits 31-39)**: the install completed but
  one or more checks failed. Set `KEEP_NAMESPACE=1` and re-run to keep
  the cluster state for `kubectl logs` / `kubectl exec` debugging.
- **Cleanup hiccup (exit 40)**: the smoke result was PASS but
  `helm uninstall` or namespace delete returned non-zero. Manual
  teardown: `kubectl delete namespace <NAMESPACE> --wait=true`.

### Anticipated failure modes

| Symptom | Likely cause | Resolution |
|---|---|---|
| `ImagePullBackOff` on `ghcr.io/john6810/unit3d` | GHCR pull secret missing on private registry path | Public pull confirmed for the published image; if the operator's fork is private, add `--set 'global.imagePullSecrets[0].name=<secret>'` and pre-create the secret in the namespace |
| PVC stuck `Pending` | StorageClass not provisioning | Check the storage provisioner pod (`kubectl -n kube-system logs <provisioner>`) and `storageclass`'s `provisioner` field |
| `unit3d-migrate` Job fails | Schema mismatch or DB credentials | `kubectl -n <NAMESPACE> logs job/<RELEASE>-unit3d-migrate` |
| `unit3d-app` Running but `port-forward` returns 502 / connection refused | FrankenPHP boot error or Caddy config issue | `kubectl -n <NAMESPACE> logs deploy/<RELEASE>-unit3d-app` |
| 500 on `/torrents` (verify 37 still PASSes — checks `/`) | UNIT3D v9.2.0 MeiliSearch `filterableAttributes` must run `scout:sync-index-settings` (already chained in the migrate Job) | Non-blocking for smoke; symptom of a partial restore on operator-managed deployments |

### See also

- [`helm/ratatoskr/`](../../helm/ratatoskr/) — the chart under test
- [`scripts/migration/`](../migration/) — migration scripts (operator
  workflow conventions for POSIX sh + traps + exit codes match)
- [`docs/architecture.md`](../../docs/architecture.md) — component
  graph and what the smoke test validates end-to-end
