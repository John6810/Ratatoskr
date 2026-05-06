# ADR-0002: Storage strategy for `unit3d-storage` — RWO PVC vs S3-compatible from day one

- **Status**: Proposed
- **Date**: 2026-05-06
- **Deciders**: <leave blank for now>
- **Tags**: `storage`, `kubernetes`, `laravel`

## Context

UNIT3D writes runtime user content to multiple Laravel filesystem disks: torrent files served back to peers, avatars and icons, torrent covers and banners, article/category/playlist images, subtitles, attachments, NFO files, and miscellaneous app cache. In the v0.1/v0.2 Compose stack this is a named volume bind-mounted into a single `unit3d` container — works because there is exactly one app replica.

The v0.3 Kubernetes overlay must commit to a storage strategy **before** the production overlay encourages operators to scale `unit3d-app`. Three shapes are technically possible:

- **RWO PVC.** A `PersistentVolumeClaim` with `accessModes: [ReadWriteOnce]` mounted into a single `unit3d-app` pod. The path of least resistance, identical mental model to Compose, but **caps `unit3d-app` at one replica forever** — no rolling deploys without downtime, no horizontal scale, no PDB-safe drains.
- **RWX PVC.** Multi-attach via NFS, CephFS, or a storage class that exposes RWX. Lets multiple `unit3d-app` pods write to a shared filesystem. Cluster-dependent (most cloud CSI drivers do not offer RWX without an extra component), and historically a source of permission/locking footguns with PHP applications.
- **S3-compatible object storage.** Configure each Laravel disk's driver as `s3` so writes go to MinIO / Cloudflare R2 / Backblaze B2 / AWS S3. Makes `unit3d-app` truly stateless. Requires a one-time migration of existing files for v0.1/v0.2 operators upgrading to v0.3.

UNIT3D v9.2.0 reality forces a **fourth shape: hybrid**. Inspection of `config/filesystems.php` and the controllers that write to those disks (verified upstream against the v9.2.0 tag — see Disk inventory below) reveals two structural constraints:

1. **No env-driven drivers.** All 17 disks defined in `config/filesystems.php` have a literal `'driver' => 'local'` (or `'s3'` for the unused default `s3` example). Nothing reads from `env()`. There is no `FILESYSTEM_DISK_*` knob at v9.2.0; flipping a disk to S3 requires a configuration override.

2. **Most write call sites bypass Laravel Storage.** The dominant pattern is `Storage::disk('<name>')->path($filename)` followed by Intervention Image's `Image::make(...)->save($path)` or Symfony's `UploadedFile::move($path, ...)`. Both write to a local filesystem path. On an S3 driver, `->path()` raises `LogicException: This driver does not support retrieving paths.` — the write fails, and even if it didn't, `->save()` would write to a local path the S3 disk cannot read back.

Three disks (`torrent-files`, `subtitle-files`, `attachment-files`) write through Storage-aware methods (`->put`, `->putFileAs`, `->storeAs`) and would S3-swap cleanly. Eight image disks plus `temporary-nfos` would not without upstream patches to the controllers.

ROADMAP v0.4 plans S3 migration with the literal claim "`unit3d-app` becomes truly stateless → `replicas: N` works." That claim is not deliverable on vanilla v9.2.0 controllers. v0.3 must either ship hybrid storage and document the constraint, or defer S3 entirely until upstream lands the controller refactor. v0.3 ships hybrid (see Decision). ROADMAP v0.4 wording needs a separate follow-up commit to align with this reality (out of scope for this ADR; tracked as a Decision consequence). <!-- VERIFY: confirm the v0.3/v0.4 split intent at release time — the boundary may shift if upstream lands the Storage-aware controller refactor before v0.3 ships. -->

The announce path (`/announce`) does not touch any of these disks — torrent file *uploads* land here, but the announce response is computed from MariaDB rows. The dedicated announce daemon planned for v0.6 will not change this storage decision.

## Decision

Ship v0.3 with **hybrid storage**. The base manifests reference a `unit3d-storage` ConfigMap + Secret pair that configures every relevant Laravel disk; overlays pick the concrete backend per disk class.

**Config override via ConfigMap, not via fork.** UNIT3D's `config/filesystems.php` ships hardcoded `'driver' => 'local'` for every custom disk. ratatoskr does not patch the upstream image — the image stays byte-identical. Instead, the prod overlay mounts a replacement `config/filesystems.php` at `/var/www/html/config/filesystems.php` via a ConfigMap volume mount. The replacement file is valid PHP, lives in this repo as a tracked text file, and rewrites the `driver` and connection details for the three Storage-aware disks (`torrent-files`, `subtitle-files`, `attachment-files`) to `s3` (env-driven). Image disks keep `local`. This is a legitimate Kubernetes deployment pattern — config overrides via ConfigMap volume mount predate ratatoskr by years and do not modify the application image.

**Disk routing in v0.3 prod**:

- **S3-backed** (Storage-aware writes, swap clean):
  - `torrent-files` — `TorrentController:347` uses `->put`
  - `subtitle-files` — `SubtitleController:100` uses `->putFileAs`
  - `attachment-files` — `AttachmentUpload` Livewire `:49` uses `->storeAs`

- **PVC-backed** (controller writes through `->path()` + Intervention `->save()`, or `UploadedFile::move()`; cannot swap to S3 without upstream PR):
  - `user-avatars`, `user-icons` (non-GIF branches; the GIF branches are Storage-aware but split routing is not worth the complexity at v0.3)
  - `torrent-covers`, `torrent-banners`
  - `article-images`, `category-images`, `playlist-images`
  - `temporary-nfos`

The Laravel-default `local` / `public` / `backups` disks stay PVC-backed for now. The `backups` write call site was not located in the v9.2.0 controller search — likely consumed by a third-party dependency; tracked as a residual VERIFY at release time. <!-- VERIFY: locate `backups` disk write call site at release time; suspected to be `spatie/laravel-backup`. -->

**Two prod operating modes**, depending on the cluster's available `StorageClass`:

- **RWX available** (NFS, CephFS, JuiceFS, Longhorn-RWX, etc.) → `unit3d-app` runs **multi-replica with HPA**, image disks share an RWX volume, real HA. Expected default for clusters that already provision a multi-attach class.
- **RWO only** (most cloud-managed K8s, csi-rawfile, single-class clusters) → `unit3d-app` runs **`replicas: 1` with `strategy: Recreate`**, image disks on a regular RWO PVC, **no HA at v0.3 prod**. Documented as a constraint of the hybrid model on RWO clusters.

App manifests stay topology-agnostic between modes — the same `unit3d-storage-config` ConfigMap and `unit3d-storage-secrets` Secret drive both. Overlay-level patches set the access mode on the PVC and the replica count + strategy on the Deployment.

All `unit3d-*` workloads (app, queue worker, scheduler) consume the same `unit3d-storage` configuration. In **dev/staging** with the RWO PVC, this forces the three pods onto the same node — Kubernetes will not schedule them across nodes since the volume cannot be multi-attached. Pod anti-affinity is intentionally not used at that overlay; spreading the pods would simply leave them Pending. In **prod RWX mode**, pods are free to scale across nodes; affinity rules become a separate concern (typically zone-spread for `unit3d-app`, handled by the prod overlay's pod topology spread constraints). In **prod RWO mode**, the same single-node constraint as dev applies, since the image PVC is RWO.

**v0.3 prod is not fully stateless.** Image disks remain on persistent storage. The ROADMAP v0.4 wording ("`unit3d-app` becomes truly stateless → `replicas: N` works") presumes upstream lands Storage-aware writes for the image controllers — out of ratatoskr's control. ROADMAP needs a follow-up commit (separate from this ADR's acceptance) that reframes v0.4 as "S3 migration once upstream image controllers are Storage-aware; tracked in `docs/upstream-prs.md`."

The v0.2 backup pipeline (`ratatoskr-backup` image) is unaffected by this ADR — it backs up MariaDB only. Backup of the storage backends themselves is v0.4 territory.

**Migration policy: v0.3 K8s overlay targets fresh deployments.** Existing v0.1/v0.2 operators on Compose **stay where they are until v0.4**. v0.4 ships a single migration tool covering both Compose → K8s relocation and the PVC → S3 split for the three Storage-aware disks in one pass — not two separate tools released sequentially. v0.3 does not provide partial migration paths; doing so would multiply the supported upgrade matrix and pull migration testing into a release whose primary scope is the K8s overlay itself. Operators evaluating v0.3 against a v0.1/v0.2 instance should provision a separate cluster, deploy v0.3 fresh, and confirm functional parity before any production migration.

## Disk inventory

The 17 disks defined in `config/filesystems.php` at the v9.2.0 tag, with their write semantics. "Storage-aware" means the controller uses `->put` / `->putFileAs` / `->storeAs` (compatible with any driver). "Path-bypass" means the controller uses `->path()` + Intervention `->save()` or `UploadedFile::move()` (locks the disk to a local filesystem until upstream refactors).

| Disk | Driver (v9.2.0) | Write style | v0.3 backend |
|---|---|---|---|
| `local` | `local` | Laravel default | PVC |
| `public` | `local` (visibility public) | Laravel default | PVC |
| `s3` | `s3` | unused example | n/a |
| `ftp` | `ftp` | unused example | n/a |
| `sftp` | `sftp` | unused example | n/a |
| `backups` | `local` | not located (suspected `spatie/laravel-backup`) | PVC (assumed) |
| `article-images` | `local` | path-bypass | PVC |
| `attachment-files` | `local` | Storage-aware | **S3** |
| `category-images` | `local` | path-bypass | PVC |
| `playlist-images` | `local` | path-bypass | PVC |
| `subtitle-files` | `local` | Storage-aware | **S3** |
| `temporary-nfos` | `local` | path-bypass (`UploadedFile::move`) | PVC |
| `torrent-banners` | `local` | path-bypass | PVC |
| `torrent-covers` | `local` | path-bypass | PVC |
| `torrent-files` | `local` | Storage-aware | **S3** |
| `user-avatars` | `local` | path-bypass (non-GIF) | PVC |
| `user-icons` | `local` | path-bypass (non-GIF) | PVC |

Verified upstream at v9.2.0; see References for raw-file URLs and controller line numbers.

## Consequences

### Positive
- **Storage abstraction layer in place for v0.4.** The `unit3d-storage-config` ConfigMap + Secret pair, per-disk routing, and ConfigMap-mounted `config/filesystems.php` override are durable contracts. If upstream lands the Storage-aware controller refactor before v0.4, the v0.3 abstraction survives intact — operators flip image disks from `local` to `s3` in the same ConfigMap pattern, no manifest rewrite. The investment is not wasted on a partial outcome.
- **PVC sizing collapses dramatically.** `.torrent` files commonly run tens to hundreds of MB each (gigabytes for large media releases) on a populated tracker; on a busy instance the `torrent-files` disk dwarfs the rest of `storage/` combined. Moving it (plus `subtitle-files` and `attachment-files`) to S3 means the remaining PVC handles only image disks, which run kilobytes per file. Expected order-of-magnitude reduction in PVC capacity requirements vs a pure-PVC overlay. The S3-backed disks pick up operator-grade backup, lifecycle, and replication semantics for free. <!-- VERIFY: tighten the GB/MB sizing claim against operator data once a real instance is observed; the order-of-magnitude framing is the load-bearing claim and is robust to specifics. -->
- **Operator chooses based on what the cluster offers.** RWX storage class available → multi-replica HA mode. RWO only → single-replica + `Recreate` mode. Same manifests, overlay-level toggle. No "your cluster is incompatible with ratatoskr" failure mode at v0.3. App manifests stay topology-agnostic between modes — operators flip an overlay value, not a manifest tree.
- **Vanilla UNIT3D image preserved, zero maintenance burden.** The config override lives in the ratatoskr repo as a tracked text file mounted at deploy time; the upstream image is byte-identical to what an unmodified `composer create-project hdinnovations/unit3d-community-edition` would produce. Upstream version bumps do not require ratatoskr-side patch reconciliation. The only ratatoskr-side maintenance task is reviewing the config override against new upstream `config/filesystems.php` on each UNIT3D bump — a five-minute diff, not a fork merge.
- **Honest scope.** v0.3 ships what works on vanilla v9.2.0; v0.4 inherits a clear upstream-PR prerequisite list rather than a vague "migrate to S3" goal. v0.4 migration is well-scoped per disk: only the three Storage-aware disks have data to relocate from the v0.3 hybrid model.

### Negative
- **v0.3 prod is partially stateless.** Image disks remain PVC-bound, so HA at v0.3 requires an RWX storage class. Self-hosters without RWX run `replicas: 1` + `strategy: Recreate`, accepting deploy-time downtime. Full statelessness is deferred to v0.4 once upstream lands Storage-aware image controllers.
- **Hybrid storage means operators configure two backends** (S3 + PVC) at v0.3 instead of one. Documented complexity that adds onboarding friction compared to a pure-S3 promise.
- New operators on the prod overlay need an S3-compatible endpoint before first boot for the three S3 disks. Document MinIO in-cluster, R2, B2, AWS S3 recipes; raise the floor compared to v0.1's "just `docker compose up`".
- **v0.1/v0.2 → v0.3 upgrade is not in-place.** Existing Compose operators must wait for v0.4's migration tool (see Decision migration policy). Operators who deploy v0.3 K8s today must provision fresh.
- Dev overlay's RWO PVC means `kubectl rollout restart deployment/unit3d-app` causes a brief outage — single-replica is enforced. Acceptable for dev, called out in the overlay comment. Same applies to RWO-mode prod. <!-- VERIFY: confirm `Recreate` strategy is set on the dev `unit3d-app` Deployment to make this explicit rather than relying on the default RollingUpdate hitting the RWO mount; same applies to RWO-mode prod. -->
- Bucket lifecycle, CORS, IAM policies, and PVC class selection are operator responsibility; ratatoskr provides example snippets but does not enforce them.
- ROADMAP v0.4 wording assumes full statelessness post-migration; that wording needs a follow-up commit to reflect the upstream-PR prerequisite. Tracked as a known doc fix outside this ADR.

### Neutral
- v0.4 migration step is now well-scoped: three disks of data to move (the Storage-aware ones), plus a hard dependency on upstream PRs for the rest. Cleaner than the original "migrate everything to S3" framing.

## Out of scope

- **Upstream PRs to make image-handling controllers Storage-aware.** Refactoring `Storage::disk(...)->path($filename)` + `Image::make(...)->save($path)` to `Storage::disk(...)->put($filename, (string) $image->encode(...))` (the correct Laravel idiom) is upstream work. Tracked separately in `docs/upstream-prs.md` (to be created in a follow-up commit). v0.4's "stateless `unit3d-app`" claim hard-depends on these PRs landing.
- **CDN integration.** Operators who want CloudFront, Cloudflare, or Bunny in front of the S3 disks configure it themselves at v0.3. ratatoskr provides the bucket-shape contract; CDN routing, signed URLs, and cache invalidation are operator responsibility.
- **Automated S3 bucket provisioning.** ratatoskr does not create buckets, IAM users, or lifecycle policies on the operator's behalf. The operator creates the bucket, generates credentials, and supplies them via `unit3d-storage-secrets`. Example `aws s3api create-bucket` and policy snippets ship in the operator guide.
- **Backup of `unit3d-storage`.** v0.2's `ratatoskr-backup` covers MariaDB only. Backup of the storage backends themselves (S3 versioning, cross-region replication, periodic restic of the bucket; PVC snapshots for image disks) is **v0.4 territory** — the migration release is the natural place to document a coherent storage backup story alongside the move.
- **v0.1/v0.2 → v0.3 migration tooling.** Out of scope per the migration policy stated in Decision. v0.4 ships a unified migration tool covering both Compose → K8s relocation and the PVC → S3 split for the Storage-aware disks; v0.3 supports fresh deployments only.

## Alternatives considered

- **Pure RWO PVC in prod (no S3 path until v0.4).** Rejected: locks `unit3d-app` to one replica for the entire v0.3 lifecycle, contradicts the "production overlay" promise, and wastes the partial S3 viability that already exists in vanilla v9.2.0. HPA would be cosmetic.
- **Pure RWX PVC in prod.** Rejected: cluster-dependent (most managed K8s do not offer RWX out of the box), historically buggy with PHP file uploads (locking, ownership, atime), and replaces a well-understood S3 contract with a fragile filesystem one. Still permitted as the "RWX mode" of the hybrid model — image disks live on RWX in that mode — but not the primary contract.
- **Pure S3 (every disk).** Rejected: not feasible on vanilla UNIT3D v9.2.0. Image controllers bypass Laravel Storage and would break on an S3 driver. Requires upstream PRs first; revisit at v0.4.
- **Maintain a ratatoskr fork that patches the controllers.** Rejected: contradicts the project rule "vanilla UNIT3D, never forked" (CLAUDE.md, ROADMAP principles). The path forward is upstream PRs, not a long-lived patch set.
- **Bundle MinIO as an in-cluster StatefulSet, default to it in prod.** Considered. Lowers the operator floor (no external S3 account needed) but ships a stateful workload that still has the same single-replica scaling problem MariaDB has at v0.3. ratatoskr will document MinIO as an *option* in the operator guide, not as a default.
- **Laravel filesystem with rclone-mounted S3 fuse for the image disks.** Rejected: adds a fuse dependency to the runtime image, performance is poor for hot-path writes, and Laravel's native S3 driver is the upstream-supported path even where it works.

## References

- ROADMAP v0.4 (S3 storage migration): [docs/ROADMAP.md](../ROADMAP.md). Wording needs a follow-up commit to align with this ADR — see Decision.
- CLAUDE.md "UNIT3D-specific pitfalls — `storage/` directory" line: [.claude/CLAUDE.md](../../.claude/CLAUDE.md)
- Laravel filesystem config: <https://laravel.com/docs/12.x/filesystem>
- UNIT3D `config/filesystems.php` at v9.2.0: <https://github.com/HDInnovations/UNIT3D/blob/v9.2.0/config/filesystems.php>
- UNIT3D `.env.example` at v9.2.0 (no `FILESYSTEM_DISK_*` keys): <https://github.com/HDInnovations/UNIT3D/blob/v9.2.0/.env.example>
- UNIT3D controllers cited in the disk inventory (all v9.2.0):
  - `app/Http/Controllers/TorrentController.php` — `Storage::disk('torrent-files')->put` at line 347 (Storage-aware); cover/banner path-bypass at lines 372, 376, 425–435.
  - `app/Http/Controllers/SubtitleController.php` — `Storage::disk('subtitle-files')->putFileAs` at line 100 (Storage-aware).
  - `app/Http/Livewire/AttachmentUpload.php` — `->storeAs(..., 'attachment-files')` at line 49 (Storage-aware).
  - `app/Http/Controllers/User/UserController.php` — path-bypass for `user-avatars` (`:91`) and `user-icons` (`:133`–`:136`); GIF branches Storage-aware.
  - `app/Http/Controllers/Staff/ArticleController.php`, `Staff/CategoryController.php`, `PlaylistController.php` — path-bypass image writes.
  - `app/Helpers/TorrentTools.php` — `UploadedFile::move` for `temporary-nfos` at line 142.
