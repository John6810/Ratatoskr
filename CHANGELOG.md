# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

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
