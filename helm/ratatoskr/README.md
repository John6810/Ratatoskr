# ratatoskr Helm chart

Deploy [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D) with
MariaDB, Redis, MeiliSearch, and FrankenPHP. See [DISCLAIMER.md](../../DISCLAIMER.md).

| Field | Value |
|---|---|
| Chart version | `0.5.0-alpha.3` |
| App version | `v9.2.0` |
| Kubernetes API minimum | `>=1.30.0-0` |
| Schema validation target | `1.32.0` |
| License | AGPL-3.0 |

The chart has no subchart dependencies. It remains alpha: ingress, KEDA parity,
production CSI/CNI qualification, and publication are separate release gates in the
[roadmap](../../docs/ROADMAP.md). `ingress.enabled=true` is explicitly rejected.

## Install

Create a private values file based on [`values.yaml`](./values.yaml), supplying:

| Value | Purpose |
|---|---|
| `unit3d.appKey` or `unit3d.bootstrapAppKey=true` | Stable Laravel encryption key |
| `unit3d.owner.email`, `unit3d.owner.password` | Initial administrator credentials |
| `mariadb.auth.rootPassword`, `mariadb.auth.password` | Embedded database credentials |
| `redis.auth.password` | Embedded Redis credential |
| `meilisearch.masterKey` | Embedded search credential, at least 16 characters |
| `unit3d.appUrl` | Public application URL |

Alternatively, reference existing Secrets with the corresponding `existingSecret`
values. The application Secret must include the configured APP_KEY key and
`DEFAULT_OWNER_NAME`, `DEFAULT_OWNER_EMAIL`, `DEFAULT_OWNER_PASSWORD` for an
initial database. Never use committed `ci/` placeholder credentials in a deployment.

```bash
helm upgrade --install ratatoskr helm/ratatoskr \
  --namespace unit3d --create-namespace -f private-values.yaml \
  --wait --wait-for-jobs --timeout 15m
helm test ratatoskr --namespace unit3d --logs
```

Use port forwarding or operator-managed ingress to reach the HTTP Service.
The application runs as UID 33; only its HTTP container adds `NET_BIND_SERVICE`
for FrankenPHP's port-80 binary. A [Pod-scoped safe sysctl](https://kubernetes.io/docs/tasks/administer-cluster/sysctl-cluster/)
sets the first unprivileged port to 80 for compatibility with older runtimes and
`allowPrivilegeEscalation=false`. Numeric worker/thread counts default to 2/4.
Health probes use curl without following `/login`, avoiding that route's rate limit.

## Installation and upgrade lifecycle

Each Helm revision creates an ordinary migration Job after its dependencies
exist. Its initializer creates Laravel storage directories and waits for the
database, Redis, and MeiliSearch. The Job migrates, seeds, and synchronizes Scout
settings. Seeders run only on a new database; `_ratatoskr_bootstrap` records
completion and blocks an automatic retry after interrupted seeding. Inspect and
repair partial seed data before setting that marker to completed. Existing databases
with users are treated as already initialized. App, queue, and scheduler init containers wait for that exact Job's
success before starting. A failed Job blocks the new workloads.

The current revision's Job remains available for logs and future Pod restarts.
Do not delete it while that revision is deployed. The next upgrade replaces it.
`migrate.timeoutSeconds` bounds dependency readiness and Job execution. Helm's
timeout must also allow image pulls and volume provisioning. Disabling migrations
is an explicit operator responsibility for an already initialized database.

Only waiting init containers mount a projected Kubernetes API token. The Role
permits `get` on the current Job only. Configure `networkPolicies.apiServerPorts`
when the control-plane endpoint uses a different port; verify enforcement with
your CNI, including Service-address translation. Defaults cover 443, 6443, 16443.

An upgrade failure does not undo database migrations. Inspect the Job logs,
correct the cause, and upgrade again; use a tested database backup when schema
recovery is needed. RWX rolling updates require backward-compatible migrations
because old replicas can continue serving while the new Job runs. RWO rollouts
use Recreate and have downtime. See [ADR-0007](../../docs/adr/0007-deployment-lifecycle.md).

HTTP Pods wait 10 seconds in `unit3d.lifecycle.preStop` before stopping the
server, allowing endpoint removal to propagate. Tune this delay and the total
termination grace period for the production ingress and longest requests.

StatefulSet claim-template labels are immutable. Fresh installs use labels
independent of chart/app versions; connected Helm upgrades preserve labels from
existing StatefulSets, including older alpha releases. When migrating an older
release through an offline GitOps renderer, explicitly retain those existing
claim-template labels in the rendered manifests. Offline `lookup` cannot read them.

## Secrets and rotation

Chart-managed credentials are created once. A cluster-side Helm `lookup` validates
and reuses existing Secrets; subsequent upgrades do not recreate them or apply
changed inline password values. Secrets survive uninstall. Back them up alongside
the database, especially APP_KEY. Bootstrap refuses to invent a replacement
APP_KEY during an upgrade if its Secret is missing.

For GitOps renderers that run offline `helm template`, use externally managed
Secrets for every component and set `unit3d.bootstrapAppKey=false`. Offline lookup
cannot preserve generated credentials. Server-side dry runs can inspect existing
Secrets; client-side renders cannot establish upgrade safety.

Password rotation is a coordinated maintenance operation: stop affected clients,
change the server credential (for MariaDB, update the existing account in SQL),
update the same Kubernetes Secret, restart dependent server/client workloads as
needed, and verify authentication. Updating MariaDB startup environment variables
does not change accounts in an initialized database. Do not delete Secrets to
rotate passwords. APP_KEY requires a separate re-encryption plan.

## External services and storage

Disable each embedded service and configure its host, port, Secret name, and
password/key field under `unit3d.database`, `unit3d.redis`, or `unit3d.meilisearch`.
Unused embedded credentials are not required. Secret keys are mapped explicitly
to the environment variables UNIT3D expects, including `MEILISEARCH_KEY`.
With NetworkPolicies enabled, external services require explicit
`networkPolicies.extraEgress` rules. The [external fixture](./ci/external-values.yaml)
shows the shape using documentation-only addresses; replace them before use.

RWO storage co-locates app, queue, scheduler, and migration Pods on one node.
Multiple replicas, including HPA maximums above one, require RWX. RWX enables
rolling app/queue upgrades; scheduler remains a single replica. Disabling the
storage PVC is rejected because UNIT3D still writes image disks locally.
The three supported S3 disks use explicitly mapped per-disk credentials; full S3
image support remains [upstream-dependent](../../docs/upstream-prs.md).

## Validation

```bash
# Requires Helm, Kustomize, kubeconform, Python 3 and PyYAML.
bash scripts/tests/validate.sh

# Explicitly select a disposable cluster; creates and cleans its own namespace.
KUBECONFIG=/path/to/disposable-kubeconfig bash scripts/tests/helm-lifecycle.sh
```

The static suite covers default, bootstrap, external, RWX, and rejected unsafe
configurations. The lifecycle suite exercises HTTP, authenticated search, stable
Secrets, chart-version upgrades, persistent data, migration failure, and recovery.
The [RWX suites](../../scripts/tests/README.md) also exercise shared storage on
different nodes and rollback to the retained RWO volume. CI also performs an
isolated physical backup/restore drill. Results and remaining limits are recorded
in the [roadmap](../../docs/ROADMAP.md#verification-evidence).
