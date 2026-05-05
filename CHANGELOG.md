# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [v0.2.0] — 2026-05-05

Backup & restore for the Compose stack. Ships a dedicated
`ratatoskr-backup` image (mariadb-backup + Restic, exact-version
matched to the MariaDB server) plus a Compose `--profile backup` for
one-shot runs. Daily snapshots stream `mariadb-backup --backup
--stream=xbstream | zstd -3 | restic backup --stdin` to any
Restic-supported backend (Backblaze B2 default; S3, R2, MinIO, SFTP,
local). 30-day retention, AES-256 client-side encryption, restore
drill, GDPR-aware operator guide. CI now publishes two multi-arch
images to ghcr.io with cosign signatures and SBOM attestations.

### ✨ Features

- `ratatoskr-backup` image — built on `mariadb:11.8` so
  `mariadb-backup` is exact-version matched with the server
  (upstream MariaDB requirement for physical hot backups). Restic
  0.18.1 fetched from the upstream GitHub release with SHA256
  verified at build for both linux/amd64 and linux/arm64. Three
  operator scripts: `backup.sh` streams the snapshot, `restore.sh`
  performs the destructive copy-back, `restore-test.sh` runs an
  end-to-end drill in an ephemeral mariadbd. Runs as the existing
  `mysql` user (UID 999), tini PID 1 for clean signal handling.
- Compose `--profile backup` override —
  `compose/docker-compose.backup.yml` with the `unit3d-backup`
  service. RW mount on `mariadb-data` (single-service Pattern X),
  gated by the script-side `RESTORE_FORCE` guard so backup mode
  never writes and restore mode requires explicit operator opt-in.
  Secrets via Docker `*_FILE` pattern, hex passwords for
  shell/SQL/JSON safety. Manual SQL snippet documented in the
  README for the MariaDB backup user — uniform across fresh and
  v0.1 upgrade paths.
- CI matrix — `.github/workflows/docker-build.yml` refactored to
  build two images in parallel (`unit3d` and `ratatoskr-backup`),
  each with its own tag plan, Trivy scan, and cosign signature.
  The `unit3d` image gets a `:ratatoskr-vX.Y.Z` alias on a tag
  push for release traceability without polluting `:latest`. Cache
  scoped per cell to avoid layer collisions.
- Multi-arch publishing pipeline — first hardening pass of the v0.1
  CI: amd64 + arm64 build, Trivy gate, cosign keyless signing, SBOM
  and provenance attestations, action versions pinned by full SHA,
  default-deny top-level permissions. Dependabot configured to
  track GitHub Actions weekly.
- `restore-drill` Claude Code skill — wraps `restore-test.sh` and
  gates any commit touching the backup pipeline. Working-tree
  semantics via bind-mount (no rebuild needed for script-only
  edits). Strict by design: no bypass flag, no cooldown, no
  auto-startup of the stack. Pre-flight aborts with actionable
  error messages.

### 🐛 Fixes

- Restic compiled from source — the upstream restic 0.18.1 binary
  is built with Go 1.25.1, which carries 9 stdlib CVEs (TLS, x509,
  URL parsing) that upstream has not yet rebuilt against a patched
  Go. The backup image now compiles restic from the v0.18.1 git
  tag (commit SHA verified at clone time) using a current Go
  toolchain in a builder stage. Same restic version, clean Trivy
  CRITICAL/HIGH posture. The pinned ARG is now the upstream commit
  SHA instead of a binary checksum — equivalent supply-chain
  assurance via a different mechanism. Also drops the unused
  `gosu` shipped by the mariadb base image (never invoked by the
  ratatoskr-backup entrypoint), removing 9 additional CVEs.
- Backup secret leakage guards — wrap the mariadb-backup pipeline
  in a `do_backup()` function and inline `MYSQL_PWD` only at the
  call site, so the password is never bound to a named shell
  variable in the parent scope and `set -x` tracing has nothing to
  print. `restore.sh` `chown` failure is now logged loudly instead
  of silently swallowed, surfacing partially-unreadable datadirs
  before mysqld refuses to start.
- Stack table accuracy — `README.md` MeiliSearch `v1.11` →
  `v1.43` (matches the compose pin), and the Reverb / WebSocket
  row dropped to match v9.2.0 reality (CLAUDE.md was already
  corrected in `7643817`; the README was missed). SFTP recipe in
  `docs/backup-restore.md` switched from `/root/.ssh/`
  (unreadable by the `mysql`-UID container) to a Docker secret +
  `RESTIC_SSH_COMMAND`, with both TOFU and pre-populated
  `known_hosts` paths documented.
- Trivy false-positive sweep — purge `linux-libc-dev` from the
  runtime image so the kernel-headers package no longer triggers
  CVE-against-the-kernel matches in scans. The runtime never
  needs kernel headers (FrankenPHP is userland only).
- MeiliSearch first-boot — `unit3d-migrate` now chains
  `scout:sync-index-settings` after `migrate --seed`. UNIT3D
  v9.2.0 declares `filterableAttributes` for the `torrents` and
  `people` indexes in `config/scout.php`, but no command pushed
  that config to MeiliSearch automatically. Result: any filter
  clause — including the `status = N` predicate that drives
  `/torrents` — threw a 400 from Meili which Laravel surfaced as
  500. The sync command is idempotent, so re-runs on container
  restart are free. `scout:import` is intentionally not chained:
  on a populated tracker it would re-index every row in 500-batch
  chunks (hours), blocking the migrate one-shot and everything
  that depends on `service_completed_successfully`.

### 📚 Docs

- MeiliSearch backfill recipe — `compose/README.md` adds a
  "Restoring MeiliSearch indexes" section documenting the manual
  `scout:flush` + `scout:import` sequence for recovery scenarios
  (Meili data loss, manual flush, post-upgrade reindex). Explicit
  "hours, not minutes — run during a maintenance window" warning
  for operators with populated trackers.
- Operator guide — `docs/backup-restore.md` covers the full v0.2
  backup pipeline: TL;DR, Mermaid sequence diagram of the
  streaming pipe, key escrow strategies (Shamir 3-of-5
  documented), one-time setup with privilege-by-privilege GRANT
  explanation, six backend recipes (Backblaze B2, Cloudflare R2,
  AWS S3 with IAM, MinIO, SFTP, local path), daily schedule (host
  cron with logrotate vs systemd timer with comparison table),
  restore procedures (drill, full destructive, partial by snapshot
  ID), GDPR honesty about the right-to-erasure limitation,
  operational footguns (multi-instance hostname clash,
  prepare-memory tuning, prune lock contention, cross-major
  restore ban), and a structured threat model with explicit
  boundaries on what the pipeline does and does not protect
  against. `THIRD_PARTY_LICENSES.md` adds AGPL attribution for
  the seven embedded components and an FSF compatibility table.
- Long-term roadmap — `docs/ROADMAP.md` from v0.2 (Backup &
  Restore) through v1.0 (Polish & Promotion). Nine intermediate
  releases each with an explicit scale envelope: K8s overlay, S3
  storage migration, Helm chart, dedicated `/announce` daemon, DB
  scale, observability, Terraform IaC. Principles up front, what
  ratatoskr is not, what is out of scope.

### Versions pinned

| Component | Pin |
|---|---|
| UNIT3D | `v9.2.0` (unchanged) |
| FrankenPHP | `1-php8.4` (unchanged) |
| MariaDB | `11` (currently 11.8.6 LTS, EOL 2028-06-04) |
| Redis | `7-alpine` (currently 7.4.8) |
| MeiliSearch | `v1.43` |
| Restic (backup image) | `v0.18.1` (new — compiled from source, commit SHA pinned) |
| Go (build toolchain) | `1.26-bookworm` (currently 1.26.2; builds the restic binary) |

### ⚠️ Breaking

- (none — MariaDB stayed on 11.8 LTS, no upgrade required for v0.1.x operators)

[v0.2.0]: https://github.com/John6810/Ratatoskr/compare/v0.1.0...v0.2.0

## [v0.1.0] — 2026-05-04

First release. Compose MVP — single-host UNIT3D v9.2.0 deployment on
FrankenPHP worker mode, with MariaDB, Redis, MeiliSearch, scheduler,
and queue worker as separate services.

### ✨ Features

- Bootstrap the FrankenPHP image for UNIT3D v9.2.0: multi-stage build
  (composer + bun in builder, lean runtime), pinned `1-php8.4` base,
  required PHP extensions, OCI labels under AGPL-3.0-or-later, and
  `HEALTHCHECK` on `/`. ([4f3207d](https://github.com/John6810/Ratatoskr/commit/4f3207d))
- Wire Octane's `frankenphp-worker.php` stub into the runtime image
  and point Caddyfile + `FRANKENPHP_CONFIG` at it, so the worker loop
  reaches `frankenphp_handle_request()`. Fixes two boot blockers in
  the same change: `composer install --no-scripts` (avoids
  `package:discover` reading env-driven config at build time) and
  `mariadb-client` in the runtime stage (Laravel `migrate` shells
  out to `mysql` for `mysql-schema.sql`). ([0218fed](https://github.com/John6810/Ratatoskr/commit/0218fed))
- Compose stack with seven services (MariaDB 11, Redis 7-alpine,
  MeiliSearch v1.43, `unit3d-migrate` one-shot, `unit3d`,
  `unit3d-scheduler`, `unit3d-queue`), real healthchecks, dependency
  chain via `service_healthy` + `service_completed_successfully`,
  named volumes, and host port bound to `127.0.0.1` only. Smoke test
  fixtures (`compose/docker-compose.test.yml` + `.env.test`) committed
  for the `docker-build-local` skill. ([10cf231](https://github.com/John6810/Ratatoskr/commit/10cf231))

### ⚖️ Legal & License

- Replace GPLv3 `LICENSE` with the canonical AGPL-3.0 text fetched
  verbatim from upstream UNIT3D. UNIT3D is AGPLv3, ratatoskr inherits
  that license, and the runtime image already declares
  `AGPL-3.0-or-later` in its OCI labels — the previous `LICENSE` was
  inconsistent with all three. ([54d4d8b](https://github.com/John6810/Ratatoskr/commit/54d4d8b))
- Add `DISCLAIMER.md` — infrastructure-only framing, operator
  responsibility (jurisdiction, DMCA, e-Commerce Directive, GDPR, ISP
  terms), legitimate-use examples, AGPL §13 obligations distinguishing
  vanilla pulls from fork-modify-distribute, AGPL §§ 15–16 warranty
  disclaimer. The dead link from `compose/README.md` now resolves.
  ([5b05456](https://github.com/John6810/Ratatoskr/commit/5b05456))

### 🐛 Fixes

- Caddyfile `php_server` block formatting. ([90646ea](https://github.com/John6810/Ratatoskr/commit/90646ea))

### 🔧 Maintenance

- Project Claude Code workspace under `.claude/`: project + global
  rules, four specialist agents (doc-writer, k8s-reviewer,
  security-auditor, laravel-unit3d-expert), six skills (version
  checks, docker build, kustomize validate, helm lint, release prep,
  README sync), `/adr` and `/commit` slash commands. ([fad028d](https://github.com/John6810/Ratatoskr/commit/fad028d))
- Align the `docker-build-local` skill with v9.2.0 reality: probe `/`
  not `/api/up`, build context = repo root, grep `unit3d-migrate`
  logs, use `--env-file compose/.env.test`. ([2fb84df](https://github.com/John6810/Ratatoskr/commit/2fb84df))

### ⚠️ Breaking

- (none — first release)

### Versions pinned

| Component | Pin |
|---|---|
| UNIT3D | `v9.2.0` |
| FrankenPHP | `1-php8.4` |
| MariaDB | `11` |
| Redis | `7-alpine` |
| MeiliSearch | `v1.43` |

[v0.1.0]: https://github.com/John6810/Ratatoskr/releases/tag/v0.1.0
