# Roadmap

> Long-term direction for ratatoskr. Not a contract — versions slip, scope evolves, the plan stays honest.

ratatoskr aims to become the reference Kubernetes deployment for [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D). Multi-level — from `docker compose up` on a 4 GB VPS to a production-grade Kubernetes deployment serving tens of thousands of concurrent users — with the same building blocks throughout.

This document tracks where we're going, what's in flight, and what's still on the drawing board. Each version is independently usable; you can stop at any level and still ship a working tracker.

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

### v0.4.0 — S3 Storage Migration & Full Statelessness 📋

Completes the storage abstraction from v0.3 and ships migration tooling. **Hard-depends on upstream UNIT3D PRs** tracked in [docs/upstream-prs.md](./upstream-prs.md) — specifically the Storage-aware refactor of image-handling controllers (avatars, icons, covers, banners, article/category/playlist images, `temporary-nfos`). Without those PRs, image disks remain PVC-bound and `unit3d-app` cannot be fully stateless.

- Storage-aware writes land upstream → image disks flip from `local` to `s3` in the `config/filesystems.php` override (same ConfigMap pattern as v0.3, no manifest rewrite)
- Documented backends: MinIO (self-hosted), Cloudflare R2 (zero egress), Backblaze B2 (cheap), AWS S3 (default mental model)
- **Unified migration tool**: covers both Compose → K8s relocation and PVC → S3 split (Storage-aware disks at v0.3, image disks once upstream lands) in one pass. v0.1/v0.2 operators become first-class upgrade citizens at v0.4. Also covers `prod-rwo` → `prod-rwx` migrations (PVC `accessModes` immutability and MariaDB VCT bump documented as the v0.3 upgrade gotchas; the tool automates the data-copy + recreate dance).
- Bucket policies, lifecycle rules, sample CORS config; storage-side backup story (S3 versioning + cross-region replication; PVC snapshots if any image disks remain)
- `unit3d-app` becomes truly stateless once upstream lands → `replicas: N` works on any cluster, RWX no longer required for HA
- **Documentation expansion**: `docs/architecture.md` (Mermaid diagrams of the Compose / Kustomize / ArgoCD topologies and the workload-to-secret wiring), `docs/upgrade-guide.md` (cross-version migrations: v0.2→v0.3 Compose-to-K8s, prod-rwo→prod-rwx, intermediate version skips), `docs/security-hardening.md` (TRUSTED_PROXIES tightening, NetworkPolicy egress fine-tuning, sealed-secrets vs ESO trade-offs in operator language), `docs/monitoring.md` (Prometheus + Grafana baseline, anticipates v0.8 observability work).
- **`ingress-vanilla` Component pivot decision**. Per ADR-0003 the Component was originally planned alongside `ingress-traefik`. Pre-v0.4 reality check: ingress-nginx is reaching EOL March 2026 (per upstream announcement), and Gateway API has matured. A successor ADR will document the choice between (a) shipping `ingress-vanilla` targeting nginx + ALB on the legacy `Ingress` API, (b) pivoting straight to a `gateway-api` Component, or (c) doubling down on `ingress-traefik` as the only first-class path. Operator-input gated.
- **Multi-queue KEDA pattern documentation**. Operators using Laravel named queues (`queue:work --queue=high,default,low`) need one ScaledObject per logical priority lane. v0.3 ships the single-queue `keda-queue-scaler` Component; v0.4 documents the multi-queue extension recipe (overlay-side patches against the Component, no Component fork required) and adds a multi-queue example overlay.
- **Helm chart prep groundwork** (full chart delivery is v0.5). v0.4 lands the chart scaffolding under `helm/unit3d/`, the `Chart.yaml` baseline, and the `values.yaml` structure mirroring the Kustomize `values.env` conventions so operators migrating Kustomize → Helm have a 1:1 value mapping. `helm-lint` skill validates the scaffold.

**Scale envelope**: app tier scales freely. DB and `/announce` become the next bottlenecks. Conditional on upstream PRs; otherwise inherits the v0.3 RWX scale envelope.

### v0.5.0 — Helm Chart 📋

Equivalent of the Kustomize tree, packaged for Helm-native operators.

- Chart structured by component (`unit3d.*`, `mariadb.*`, `redis.*`, `meilisearch.*`)
- Subchart toggles (`mariadb.enabled`, etc.) so operators can bring their own managed DB
- Optional Bitnami subcharts as dependencies, custom fallbacks if disabled
- Pre-install hooks for migrations
- Helm tests
- Published to Artifact Hub
- `helm-lint` skill validates every PR

**Scale envelope**: same as v0.3, but with the Helm UX.

### v0.6.0 — High-Performance `/announce` ⭐ 📋

The technical differentiator. Decouples the BitTorrent announce path from PHP.

- Dedicated daemon ([aquatic](https://github.com/greatest-ape/aquatic) Rust, or [chihaya](https://github.com/chihaya/chihaya) Go) handles `/announce`
- Periodic sync from daemon to UNIT3D MariaDB via Redis pub/sub or batched writes
- UNIT3D web UI continues to serve everything else (search, profile, upload, etc.)
- Routing rule on the Ingress sends `/announce` to the daemon, everything else to PHP
- Migration path documented for existing operators (no breaking change to the announce URL)

This is what existing UNIT3D deployments do not have. PHP serving 10,000 peer announces per second is wasted compute.

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