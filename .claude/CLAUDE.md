# CLAUDE.md — ratatoskr

> Project-level instructions for Claude Code. Always loaded — keep tight.

## Project

**ratatoskr** is a production-grade deployment stack for [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D), the Laravel-based private BitTorrent tracker. It fills a real ecosystem gap: no official Helm chart, no GitOps blueprint, dead community Compose files. We ship four progressive levels — Compose → K3s → multi-node K8s (Kustomize + ArgoCD) → Terraform IaC — built around a single FrankenPHP image.

**Infrastructure only.** Treat like Nextcloud or Jellyfin: dual-use, lawful purposes only. Operators are responsible for what they distribute.

## Legal — non-negotiable

- License: **AGPL-3.0**, inherited from upstream UNIT3D. Never propose changing it.
- Vanilla image pulls + manifests do not trigger AGPL obligations on operators. Modified-and-redistributed images do.
- Never write content that suggests, implies, or facilitates piracy. Examples assume legitimate content (Linux ISOs, public datasets, self-produced media).

## Stack — verify before pinning

| Layer | Choice | Pin |
|---|---|---|
| Application | UNIT3D | `v9.2.0` |
| Runtime | FrankenPHP worker mode | `1-php8.4` |
| Database | MariaDB | `11` |
| Cache / queues / broadcast | Redis | `7` |
| Search | MeiliSearch | latest stable (verify) |
| Broadcasting | Laravel broadcast, Redis driver | bundled (`BROADCAST_CONNECTION=redis`) |

Mismatches between this file and reality have happened. Run the `check-upstream-versions` skill before pinning anything new, and update code + this table in the same commit.

**No WebSocket server.** UNIT3D v9.2.0 does not bundle Reverb (or Soketi, or any WebSocket broker) — verified against `composer.json`, `config/broadcasting.php`, `package.json`, and `.env.example` at the v9.2.0 tag. Server-side broadcasting works through Redis pub/sub for queue jobs and inter-process events; there is no browser-facing WS path for live chat or presence in the vanilla install. Real-time UI is upstream's responsibility — if a future UNIT3D release adopts Reverb (or anything else), ratatoskr will add the matching service and update this table in the same commit.

## Conventions

**Commits**: Conventional Commits, atomic, one logical change. `feat(helm): add reverb subchart`, `fix(docker): correct storage perms`. No "wip" or "fix typo" reaches main.

**Branches**: `main` protected, `feat/<slug>`, `fix/<slug>`, `chore/<slug>`.

**K8s naming**: namespace `unit3d`, resources named `<component>` (e.g. `mariadb`, `unit3d-app`, `unit3d-queue`). Recommended labels (`app.kubernetes.io/*`) on every resource.

**Image registry**: `ghcr.io/john6810/unit3d:<unit3d-version>`, plus `<version>-<sha>` for reproducibility.

**Secrets**: never plaintext, even in `.env.example` (use `CHANGEME`). Sealed-secrets is the default pattern. `APP_KEY` is generated once and never regenerated.

## UNIT3D-specific pitfalls

These are not obvious and break deployments. Flag them when relevant:

- **`storage/` directory** — UNIT3D writes avatars, banners, `.torrent` files. Multi-replica needs RWX (rare) or, preferably, a Laravel filesystem migration to S3-compatible. Default S3 in production overlays; PVC RWO only for single-replica setups.
- **Announce URL is permanent** — once `.torrent` files are distributed, the announce URL is baked in forever. Domain choice is a one-way door.
- **MeiliSearch is single-node** — no native HA. Document snapshot/restore. Acceptable degradation: search falls back to SQL `LIKE`.
- **Migrations before app pods** — Helm pre-install hook or init Job. Never bake `php artisan migrate` into the main pod entrypoint.
- **First boot needs owner bootstrap** — `DEFAULT_OWNER_*` env vars create the initial admin. Document this.
- **No WebSocket server in v9.2.0** — broadcasting is Redis pub/sub only, no browser-facing WS. If a future UNIT3D release adopts Reverb (the Laravel 11+ canonical path), ratatoskr will follow upstream rather than fork-ship a Reverb container that vanilla UNIT3D can't talk to.

## Style for generated content

- **English** in all public artifacts (README, docs, code comments, commit messages, log strings).
- Direct, concrete. No "leveraging", "solutions", "enterprise-grade".
- Code examples runnable as-is. Mermaid for architecture diagrams.
- Sparse, sober emojis in docs OK (`⚠️`, `✅`). None in commits or code.

## References

- UNIT3D: <https://github.com/HDInnovations/UNIT3D> · `.env.example`: <https://github.com/HDInnovations/UNIT3D/blob/master/.env.example>
- FrankenPHP: <https://frankenphp.dev>
