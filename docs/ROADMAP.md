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

### v0.2.0 — Backup & Restore — In progress 🚧

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

### v0.3.0 — Kubernetes Production Overlay 📋

The first real Kubernetes deployment path. Targets a 3-node cluster.

- `kustomize/base/` for all components, overlays for `dev` / `staging` / `prod`
- StatefulSet MariaDB with `csi-rawfile` or equivalent, PVC for data
- Deployment + HorizontalPodAutoscaler on `unit3d-app` (CPU + KEDA Redis-queue-length)
- Separate Deployments for queue worker and scheduler (CronJob)
- NetworkPolicy default-deny + explicit allows (CoreDNS egress, intra-namespace, ingress)
- PodDisruptionBudget on every workload with HPA
- Ingress via Traefik IngressRoute + cert-manager (Let's Encrypt)
- ArgoCD `ApplicationSet` template for GitOps adoption
- `kustomize-validate` skill catches manifest drift before commit
- `k8s-reviewer` agent runs on every PR touching manifests

**Scale envelope**: 5,000–10,000 active users on a 3-node cluster.

### v0.4.0 — S3 Storage Migration 📋

Removes the single-replica RWO ceiling for the application tier.

- Laravel `FILESYSTEM_DISK=s3` configuration baked into overlays
- Documented backends: MinIO (self-hosted), Cloudflare R2 (zero egress), Backblaze B2 (cheap), AWS S3 (default mental model)
- Migration script for existing Compose / K3s deployments (avatars, banners, `.torrent` files)
- Bucket policies, lifecycle rules, sample CORS config
- `unit3d-app` becomes truly stateless → `replicas: N` works

**Scale envelope**: app tier scales freely. DB and `/announce` become the next bottlenecks.

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