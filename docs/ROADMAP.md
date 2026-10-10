# Roadmap

> Long-term direction for ratatoskr. Not a contract — versions slip, scope evolves, the plan stays honest.

ratatoskr aims to become the reference Kubernetes deployment for [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D). Multi-level — from `docker compose up` on a 4 GB VPS to a production-grade Kubernetes deployment serving tens of thousands of concurrent users — with the same building blocks throughout.

This document tracks where we're going, what's in flight, and what's still on the drawing board. Each release is intended to offer a usable deployment level; current blockers and verification evidence are recorded below.

## Current assessment — review of `daeca89` (2026-10-10)

The review findings are corrected in the working tree, chart `0.5.0-alpha.3`.
Installation, upgrade, migration failure/recovery, and physical backup/restore
now have executable regression coverage. The chart remains alpha; deployment
stabilization comes before ingress parity, Gateway API, database HA, and Terraform.
Historical releases below describe shipped scope, not certification of every path.

### Review findings and corrections

| ID | Priority | Original defect | Implemented correction |
|---|---|---|---|
| R1 | P1 | Smoke preflight failure could delete an existing namespace. | Cleanup requires creation by this invocation and the original namespace UID. Existing namespaces, creation races, replacement, and failed install paths are tested. PASS is emitted after cleanup. |
| R2 | P1 | RWO→RWX finalization reset the released source PV to Delete. | Keep Retain until explicit operator reclamation. Rescue PVC preserves the old StorageClass; binding waits follow loader creation for WaitForFirstConsumer. |
| R3 | P1 | Restore erased the target before downloading/preparing the backup. | Prepare first, retain all originals including dotfiles, recover them after copy-back failure, and keep the original datadir until verification. |
| R4 | P1 | Pre-install migration hook depended on resources not created yet. | Ordinary revision-specific Job, dependency/storage initializer, and application startup gates. Scoped API RBAC and projected init-only tokens. |
| R5 | P1 | MeiliSearch master key was not mapped to the Scout client variable. | Explicit MEILISEARCH_KEY references across Helm and Kustomize; authenticated Scout synchronization is exercised. |
| R6 | P1 | Credential hooks could recreate Secrets and change APP_KEY on upgrade. | Cluster-side lookup preserves existing credentials; bootstrap generates once and fails closed on a missing upgrade key. Offline GitOps uses existing Secrets. Rotation guidance corrected. |
| R7 | P2 | Smoke looked for a Job already deleted by hook cleanup. | Current revision's Job stays available for logs and Pod restarts; actual smoke success and namespace cleanup verified. |
| R8 | P2 | Ingress was a no-op; external credentials and custom key names were inconsistent. | Unsupported ingress/storage modes fail explicitly. External-only schema, explicit key mapping, egress configuration, service accounts, probes, RWO scheduling/HPA limits, and RWX rolling strategy are wired and tested. |

Real execution also exposed and fixed missing image CMD, invalid `auto` worker
counts, FrankenPHP's port-80 capability/runtime requirements, and health-probe redirects
hitting the login rate limit. Upstream seeders are not all idempotent: the shared
Docker/Helm/Kustomize lifecycle now serializes migration Jobs and seeds a new
database once. An interrupted seed leaves a durable marker that requires inspection
before retrying. The restore drill now explicitly connects to its temporary Unix
socket and verifies the server identity; backup-image shell arguments are preserved.
Init waits explicitly handle SIGTERM so cancellation does not inherit a worker
Pod's hour-long grace period.

Multi-node execution then exposed immutable StatefulSet claim-template labels,
an HTTP connection reset during rollout, and NFS copy/verification edge cases.
Chart `0.5.0-alpha.3` preserves existing claim labels and gives HTTP endpoints
10 seconds to drain before stopping. The storage migration validates the target
PVC before stopping workloads, removes completed migration Pods before the swap,
copies dotfiles without modifying the provisioner's mount-root metadata, and
checks every regular file with SHA-256. Read failures now abort verification.

Design and operating constraints: [ADR-0007](./adr/0007-deployment-lifecycle.md),
[Helm guide](../helm/ratatoskr/README.md), [upgrade guide](./upgrade-guide.md),
[restore guide](./backup-restore.md), and [migration script guide](../scripts/migration/README.md).

### Verification evidence

| Check | Result |
|---|---|
| Safety/configuration regression suite | 20 tests; namespace ownership, restore failures, retained PV, checksum I/O failures, immutable claim labels, and Helm configuration contracts |
| Strict Helm lint and Kubernetes/CRD schemas | 238 resources across four Helm variants and three Kustomize overlays |
| Application and backup Docker images | Built locally from this checkout |
| Compose smoke | Healthy services, HTTP 302, initial seeding, successful second migration, SIGTERM cancellation of init waits, cleanup |
| Helm lifecycle on disposable Kind | Fresh bootstrap, HTTP and authenticated search, stable credentials/data on upgrade, failed-migration gate, recovery, and external services with custom Secret keys |
| Multi-node Helm RWX lifecycle | Real static NFS 4.0 mounts, two app replicas on different nodes, chart-version upgrade, old replicas remain available through a deliberately failed migration, Helm rollback, recovery, and authenticated external search |
| RWO→RWX migration and storage rollback | Real copy of 132 test files plus symlink, full SHA-256 verification, stable APP_KEY and SQL sentinel, cross-node writes, Pod replacement, then successful rebind and restart on the retained original RWO PV |
| HTTP during a local rolling upgrade | 367 requests, zero failures, p95 5.95 ms after adding the drain delay; the earlier run exposed one connection reset |
| Browser session | Administrator login, torrent listing and an empty search result render correctly; authenticated session survives the upgrade |
| Helm smoke script | All nine checks pass; final PASS after namespace cleanup |
| Kustomize dev on disposable Kind | Fresh install, actual APP_KEY generation, repeat bootstrap preserves key, HTTP 302, authenticated Scout synchronization |
| Physical backup/restore drill | Real MariaDB → mariadb-backup → zstd → encrypted Restic → prepare/copy-back → temporary DB queries; forced replacement preserves originals |
| CI | New deployment-and-recovery workflow defines static, Compose, Helm/Kustomize lifecycle, multi-node NFS CSI, smoke, and backup/restore jobs; remote Actions execution requires a push |

Local validation uses Helm 3.16.4, Kustomize 5.8.3, kubeconform 0.8.0, and
Kubernetes 1.32.0 schemas. Helm lifecycle, Kustomize bootstrap, and smoke tests
passed on isolated Kind clusters running both 1.32.0 and 1.37.0. CI uses the 1.32
baseline. A separate three-node `ratatoskr-local` cluster now serves a local demo
on loopback port 8080; pre-existing clusters and the default kubeconfig were not
modified. Kind enforces NetworkPolicy; lifecycle API access and explicitly allowed
external-service traffic are exercised.

The local RWX tests use precreated NFS PVs. Downloads of NFS CSI images failed
with registry TLS/timeouts, so dynamic provisioning remains unverified. NFS 4.0
avoids a confirmed Ganesha/Linux 6.19+ directory-delegation incompatibility without
changing host kernel parameters; see the [test guide](../scripts/tests/README.md).
The fresh-cluster wrapper also needs an end-to-end CI run: creating a second
concurrent three-node Kind cluster failed during node startup, before any tests.
The individual RWX suites run against the existing local cluster. Production
CSI/CNI, ingress, S3 backends, load, and dependency freshness remain separate
checks. The HTTP sample above measures a local redirect during rollout, not
authenticated application throughput or a production availability guarantee.

### Next work, in order

1. Run the new CI on the 1.32 baseline and qualify the lifecycle suite on the
   intended production CNI, including API-server and external-service egress.
2. Repeat the multi-node RWX suites with the production CSI drivers on disposable
   data, including dynamic provisioning and retained-volume rollback. Measure
   interruption with the intended ingress and a realistic authenticated workload.
3. Complete supported Helm beta delivery: ingress, KEDA parity, chart publication,
   and release documentation. `ingress.enabled=true` currently fails explicitly.
4. Write ADR-0006 for Gateway API alongside Traefik, implement the routing resources,
   and validate the storage/ingress matrix while preserving the `/announce` contract.
5. Re-audit upstream S3 image support and establish a measured load baseline before
   committing to an announce daemon, Galera, or numerical capacity targets.

Full S3 image storage remains upstream-dependent. All scale envelopes below are
planning targets, not benchmark results.

## Principles

- **Vanilla UNIT3D, never forked.** ratatoskr packages and deploys upstream UNIT3D. We do not ship a modified application image. If a feature is needed, we ask upstream first.
- **Multi-level honesty.** Compose / K3s / K8s prod / IaC must all stay coherent. A decision at level 1 (named volumes, no `:latest`, etc.) carries through to level 4. No "different stack at scale".
- **Production-grade from day one.** Supply chain security (Cosign, SBOM, provenance), real backups (mariabackup + Restic, not naive volume snapshots), pinned versions, atomic commits.
- **Infrastructure only.** ratatoskr is dual-use deployment tooling. Operators are responsible for what they distribute. See [DISCLAIMER.md](../DISCLAIMER.md).
- **AGPL-3.0 inherited from upstream.** Non-negotiable.

## Versions

### v0.1.0 — Compose MVP — Released 2026-05-04 ✅

First public release. Single-host stack runnable in 5 minutes.

- FrankenPHP image for UNIT3D v9.2.0 (`ghcr.io/john6810/unit3d`)
- Docker Compose stack: MariaDB, Redis, MeiliSearch, scheduler, queue worker, migrate one-shot
- Smoke-test fixtures
- GitHub Actions CI: multi-arch build, Trivy scan, Cosign keyless signing, SBOM + provenance

**Scale envelope**: 50–500 active users, single VPS.

### v0.2.0 — Backup & Restore — Released 2026-05-05 ✅

The piece that makes v0.1 actually deployable for real.

- `ratatoskr-backup` image (`mariadb:11.8` base + Restic 0.18+ pinned by SHA256)
- `mariabackup` hot physical backups, streamed through `zstd` and `restic`
- AES-256 client-side encryption mandatory (GDPR-aware defaults)
- Daily schedule, 7 local + 30 remote retention
- Backblaze B2 documented as default backend (Restic supports any S3-compat / SFTP / Azure / local)
- Restore drill: ephemeral DB instance + sanity queries + manifest comparison
- New Claude Code skill `restore-drill` gating commits that touch backup scripts
- Operator guide covering encryption strategy, GDPR retention rules, host cron setup

**Scale envelope**: same as v0.1, but recoverable.

### v0.3.0 — Kubernetes Production Overlay — Released 2026-05-08 ✅

The first real Kubernetes deployment path. Architectural decisions captured in [ADR-0001](./adr/0001-database-deployment-topology.md), [ADR-0002](./adr/0002-storage-strategy-unit3d-storage.md), [ADR-0003](./adr/0003-ingress-controller-assumption.md), [ADR-0004](./adr/0004-secret-management.md), and [ADR-0005](./adr/0005-ha-boundary-v0.3.md).

- ✅ `kustomize/base/` (23 resources) and three overlays — `dev`, `prod-rwo`, `prod-rwx`. `staging` was dropped from scope: operator-tunable values on `prod-rwo`, not a distinct overlay tree (the differentiator that warrants a dedicated overlay is the storage access mode, not the deployment environment).
- ✅ **MariaDB**: embedded StatefulSet, single-replica until v0.7 Galera per ADR-0001. The managed-DB toggle (RDS / Aiven / OVH) is documented in ADR-0001 but not yet shipped as a Kustomize component — operators on managed DB wire the connection manually at v0.3.
- ✅ **`unit3d-storage`**: hybrid storage per ADR-0002 — three Storage-aware disks (`torrent-files`, `subtitle-files`, `attachment-files`) flip to S3 in `prod-rwx`; image disks stay on PVC pending upstream Storage-aware-writes refactor (tracked in [docs/upstream-prs.md](./upstream-prs.md), v0.4 dependency). ConfigMap-mounted `config/filesystems.php` override preserves the vanilla UNIT3D image.
- ✅ HPA on `unit3d-app` (CPU 70 + Memory 80, min 2 / max 10) and on `unit3d-queue` (CPU 70, min 2 / max 8) at `prod-rwx`. KEDA Redis-queue-length scaler shipped as opt-in Component (`components/keda-queue-scaler`) — replaces the CPU HPA on `unit3d-queue` when activated; the two are mutually exclusive.
- ✅ Separate Deployments for queue worker (`queue:work`) and scheduler. **Scope evolution**: scheduler is a long-running Deployment running `php artisan schedule:work` (Laravel 10+ self-scheduling primitive), not a CronJob. Scheduler is a hard single-replica per ADR-0005 (multiple schedulers = duplicate cron firings).
- ✅ NetworkPolicy default-deny + explicit allows (CoreDNS egress, intra-namespace, `unit3d-app` ingress, `unit3d-egress-https`). 8 NetworkPolicies under `kustomize/base/networkpolicies/`.
- ✅ PodDisruptionBudget on `unit3d-app` and `unit3d-queue` (`minAvailable: 1`) at `prod-rwx`. No PDB on `unit3d-scheduler` (single-replica makes PDB meaningless).
- ✅ **Ingress** via the `ingress-traefik` Component (Traefik `IngressRoute` + Middlewares + cert-manager `ClusterIssuer` + `Certificate`). Two-Route split structurally enforces the `/announce` no-middleware contract per ADR-0003. `ingress-vanilla` Component deferred to v0.4 (per ADR-0003 amendment — operator-demand-gated). TLS-source toggle (`letsencrypt` / `external` for upstream LB) honored. Trusted proxy headers mandatory.
- ✅ **Secrets**: sealed-secrets default per ADR-0004, with `secrets-templates/` reference subdirectory under `kustomize/base/`. `<component>-secrets` naming convention enforced. `APP_KEY` operator-supplied via sealed-secrets in prod; opt-in `bootstrap-app-key` Component for "deploy-and-go" first-time operators. ESO alternative documented in ADR-0004; the ESO toggle Component itself is not shipped (operators wire `ExternalSecret` manifests manually).
- ✅ ArgoCD `ApplicationSet` template under `argocd/` with Git directory generator + 3 usage patterns (smoke-test, single overlay, multi-cluster Matrix).
- ✅ `kustomize-validate` skill catches manifest drift before commit; `k8s-reviewer` agent runs on every PR touching manifests.
- ✅ **Dockerfile entrypoint cgroup-aware GOMEMLIMIT** (commit `64a5d7c`) — reads pod cgroup memory limit at start and sets `GOMEMLIMIT` to 90% to prevent OOMKill events under Go GC pressure. Operator override preserved.
- ✅ **Migration policy**: targets fresh deployments. Existing v0.1/v0.2 Compose operators stay on Compose until v0.4 ships unified migration tooling.

**Scale envelope**: 5,000–10,000 active users on a 3-node cluster (`prod-rwx` mode). `prod-rwo` mode caps at single-replica throughput, suitable for ~1K-3K active users.

### v0.4.0 — Documentation expansion & migration tool — Released 2026-05-08 ✅

Operator-facing documentation cycle and migration tooling. Five operator-facing docs that take a v0.3 deployment to a confidently-operated production posture (architecture, upgrade-guide, security-hardening, monitoring, multi-queue-scaling), plus two POSIX sh migration scripts that automate the upgrade-guide procedures (in-place RWO→RWX PVC swap, guided 8-step Compose → K8s stepper with state persistence). The S3 storage scope originally planned for v0.4.0 is upstream-PR-gated and tracked in v0.4.1 below.

- ✅ `docs/architecture.md` (`11bd666`) — component graph, storage strategy, request flow (3 Mermaid diagrams).
- ✅ `docs/upgrade-guide.md` (`52ac5ca`) — three migration paths (Compose → K8s, prod-rwo → prod-rwx, UNIT3D version bumps).
- ✅ `docs/security-hardening.md` (`f7af3a4`) — production hardening recipes (NetworkPolicy egress, sealed-secrets vs ESO, TLS posture, container hardening, database hardening).
- ✅ `docs/monitoring.md` (`4e09e5c`) — observability baseline (Prometheus + Grafana + Loki + Alloy) with five baseline PrometheusRule alerts and per-component ServiceMonitor examples.
- ✅ `docs/multi-queue-scaling.md` (`8ad8a42`) — KEDA multi-lane pattern, hybrid Component+inline shape, decision tree (Mermaid), 5 anti-patterns.
- ✅ **Unified migration tool** (`03b8aaf`, `496f506`): `scripts/migration/migrate-rwo-to-rwx.sh` covers in-place RWO→RWX PVC swap (Option B); `scripts/migration/migrate-compose-to-k8s.sh` covers Compose → K8s as a guided 8-step stepper with state persistence and three secrets-mode paths (sealed-secrets / ESO / vanilla). v0.1/v0.2 operators become first-class upgrade citizens.

**Scale envelope**: same as v0.3 — operators now have the documentation and tooling to actually upgrade into it.

### v0.4.1 — S3 storage migration [upstream-PR-gated, ETA TBD] 📋

This point release lands the storage scope originally planned for v0.4.0. **Hard-depends on upstream UNIT3D PRs** tracked in [docs/upstream-prs.md](./upstream-prs.md) — specifically the Storage-aware refactor of image-handling controllers (avatars, icons, covers, banners, article/category/playlist images, `temporary-nfos`). Tag will be cut once the upstream PRs land and ratatoskr's S3 routing flips for the image disks.

- Storage-aware writes land upstream → image disks flip from `local` to `s3` in the `config/filesystems.php` override (same ConfigMap pattern as v0.3, no manifest rewrite)
- Documented backends: MinIO (self-hosted), Cloudflare R2 (zero egress), Backblaze B2 (cheap), AWS S3 (default mental model)
- Bucket policies, lifecycle rules, sample CORS config; storage-side backup story (S3 versioning + cross-region replication; PVC snapshots if any image disks remain)
- `unit3d-app` becomes truly stateless once upstream lands → `replicas: N` works on any cluster, RWX no longer required for HA

**Scale envelope**: app tier scales freely. DB and `/announce` become the next bottlenecks. Conditional on upstream PRs; otherwise inherits the v0.3 RWX scale envelope.

### v0.5.0 — Helm chart, then ingress parity — In progress

The chart at [`helm/ratatoskr/`](../helm/ratatoskr/) is `0.5.0-alpha.3`.
R1–R8 and the runtime startup/seed defects are corrected with local regression
coverage. There are no external subchart dependencies.

Implemented:

- Component resources, values/schema, explicit credential mapping, and external services.
- Revision-specific migration Jobs, startup gates, first-install seeding, retained Secrets.
- NetworkPolicies, RWO co-location, RWX rolling app/queue updates, optional HPA/PDB.
- Helm HTTP tests and static/lifecycle/backup-restore CI jobs.
- Safe smoke cleanup, retained source volumes, and failure-preserving restores.

Still required before beta/publication:

- Run the new CI remotely and close the production CNI/CSI checks above.
- Implement ingress templates and Gateway API/Traefik parity (ADR-0006).
- Port the opt-in KEDA scaler and enforce mutual exclusion with queue HPA.
- Publish the chart and Artifact Hub metadata after release gates pass.

**Scale envelope**: same as v0.3, with Helm UX and a second supported ingress path.

### v0.6.0 — High-Performance `/announce` ⭐ 📋

Feasibility track after deployment stabilization and load measurement. Decouples the BitTorrent announce path from PHP only if an ADR establishes compatible private-tracker authentication, accounting, and failure behavior.

- Dedicated daemon ([aquatic](https://github.com/greatest-ape/aquatic) Rust, or [chihaya](https://github.com/chihaya/chihaya) Go) handles `/announce`
- Periodic sync from daemon to UNIT3D MariaDB via Redis pub/sub or batched writes
- UNIT3D web UI continues to serve everything else (search, profile, upload, etc.)
- Routing rule on the Ingress sends `/announce` to the daemon, everything else to PHP
- Migration path documented for existing operators (no breaking change to the announce URL)

Benchmark the current PHP path first. A generic tracker daemon is not a drop-in replacement for UNIT3D's private-tracker behavior; integration requirements and any upstream dependency must be explicit before implementation.

**Scale envelope**: hundreds of thousands of concurrent peers, web UI scales independently.

### v0.7.0 — Database Scale 📋

Removes the last single-instance bottleneck.

- Option A: MariaDB Galera 3-node cluster with HAProxy / MaxScale
- Option B: Single primary + N read replicas via ProxySQL or built-in async replication
- Laravel multi-DB config: writes to primary, listings/searches to replicas
- Connection pooling documented (PgBouncer-style for MariaDB via ProxySQL)
- Failover playbooks
- ADRs documenting the Galera vs replica trade-off

**Scale envelope**: tens of thousands of active users sustained.

### v0.8.0 — Observability 📋

Production operability.

- Prometheus operator + ServiceMonitors for each component
- Pre-built Grafana dashboards (UNIT3D-specific: ratio distribution, peer load, queue depth, scheduler lag)
- Loki for centralized logs
- Sentry integration for PHP error tracking
- Alerting rules (DB connection saturation, queue backlog, abnormal announce rate, certificate expiry)

**Scale envelope**: same as v0.7, but actually operable when it breaks.

### v0.9.0 — Terraform IaC 📋

Provision the cluster, not just the workload.

- Modules for Hetzner Cloud, OVH, FlokiNET (custom API), DigitalOcean
- Bootstrap [Talos Linux](https://www.talos.dev) or K3s on top
- One-command deploy of a complete ratatoskr cluster from scratch
- State management documented (S3-compatible backends, OpenTofu compatibility)

**Scale envelope**: reproducibility, not raw performance — but enables DR drills.

### v1.0.0 — Polish & Promotion 📋

Public launch.

- Bilingual documentation (EN primary, FR mirror)
- Complete ADR set documenting every non-obvious decision
- Demo video / screencast
- Posts on r/selfhosted, r/laravel, r/kubernetes, Hacker News
- Technical blog post on the FrankenPHP + dedicated announce daemon hybrid pattern

## What this isn't

- **A bare-metal install script.** Use the upstream UNIT3D installer for that.
- **A managed SaaS.** ratatoskr is what you self-host; we do not run it for anyone.
- **A multi-tenant platform.** One ratatoskr deployment = one tracker. Operators who want N trackers run N deployments.
- **An invitation to ignore copyright.** See [DISCLAIMER.md](../DISCLAIMER.md).

## Out of scope (for now)

These come up in discussion but are not on the roadmap. They might land later if a real operator demand emerges:

- WebSocket layer (Reverb / Pusher). Not in upstream UNIT3D v9.2.0; we will not bundle it as an opinion.
- IPv6-only deployments. Should work but not actively tested.
- Multi-region active-active. The single-region case isn't solved at the scale we care about yet — start there.
- Custom UNIT3D theming or feature patches. Belongs upstream, or in a fork.

## How decisions get made

Anything non-trivial — backup tool choice, announce daemon selection, DB scale path — gets an [Architecture Decision Record](./adr/) before code lands. ADRs explain the context, the alternatives considered, and the trade-offs. Older decisions can be revisited; ADRs are amended, not silently overwritten.

## Contributing to the roadmap

Open an issue tagged `roadmap` to propose a change of priorities, a new version, or a removal. The maintainers will respond with a yes / no / later, and either way the conversation stays public.
