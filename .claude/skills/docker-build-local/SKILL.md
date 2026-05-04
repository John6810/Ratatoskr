---
name: docker-build-local
description: Build the ratatoskr UNIT3D FrankenPHP image locally and run a smoke test against a minimal Compose stack (MariaDB, Redis, MeiliSearch). Verifies the image starts, migrations run, and the /api/up health endpoint responds. Use after any change to the Dockerfile, entrypoint, Caddyfile, PHP config, or composer/bun lockfiles. Also use before tagging a release or pushing to ghcr.io. Tears down all resources at the end, even on failure.
allowed-tools: Bash(docker build:*), Bash(docker buildx:*), Bash(docker compose:*), Bash(docker images:*), Bash(docker ps:*), Bash(docker logs:*), Bash(docker inspect:*), Bash(docker exec:*), Bash(docker stop:*), Bash(docker rm:*), Bash(docker network:*), Bash(docker volume ls:*), Bash(grep:*), Bash(rg:*), Bash(cat:*), Bash(sleep:*), Read, Glob
---

# Docker build & local smoke test

Build the FrankenPHP image and run a minimal end-to-end smoke test. The goal is to catch in 60 seconds the kind of regressions that would otherwise blow up only at deploy time: missing PHP extension, broken entrypoint, wrong storage permissions, migration failure, MeiliSearch not reachable.

## When to invoke

- After any change in `docker/` (Dockerfile, entrypoint, Caddyfile, php conf)
- After bumping `UNIT3D_VERSION`, FrankenPHP base tag, MariaDB/Redis/MeiliSearch versions
- Before tagging any release
- Before manually approving a `docker push` to `ghcr.io/john6810/unit3d`
- When the user asks "does it still boot?", "test the image", "smoke test"

## Conventions for this skill

- Local image tag: `ratatoskr/unit3d:dev` (never push, never tag with a real version)
- Compose project name: `ratatoskr-test` (isolates from dev compose)
- Test stack file: `compose/docker-compose.yml` + override `compose/docker-compose.test.yml`
- All containers, networks, and volumes are torn down at the end — including on failure

## Workflow

### 1. Pre-flight

```bash
docker --version
docker compose version
test -f docker/Dockerfile || { echo "No Dockerfile yet — skill cannot run"; exit 1; }
test -f compose/docker-compose.yml || { echo "No compose file yet — skill cannot run"; exit 1; }
```

If either prerequisite is missing, stop and tell the user the prerequisite is missing instead of failing silently.

### 2. Build the image

```bash
docker build \
  --tag ratatoskr/unit3d:dev \
  --build-arg UNIT3D_VERSION="$(grep -oP '(?<=ARG UNIT3D_VERSION=)\S+' docker/Dockerfile || echo v9.2.0)" \
  --progress=plain \
  docker/
```

If build fails, capture the last 50 lines of build output, identify whether the failure is in the builder stage (composer/bun) or runtime stage (extensions, perms), and report it. Do not proceed.

### 3. Boot the test stack

Use the test override (it must exist; if not, ask the user to create one — do not improvise random ports and credentials):

```bash
docker compose \
  --project-name ratatoskr-test \
  --file compose/docker-compose.yml \
  --file compose/docker-compose.test.yml \
  up -d --wait --wait-timeout 120
```

`--wait` blocks until all services are healthy according to their `healthcheck` definitions. If it times out, immediately collect logs (step 6) before tearing down.

### 4. Wait for migrations and seeders

UNIT3D's first boot requires `php artisan migrate --force` and the owner seeder. The entrypoint should handle this. Verify it ran:

```bash
docker compose --project-name ratatoskr-test logs unit3d 2>&1 | grep -E "Migration|Migrated|Seeded|owner"
```

Expected to see `Migrating:` and `Migrated:` lines, plus a confirmation that the default owner was created. If absent after 60s of boot, treat as a failure.

### 5. Hit the health endpoint

UNIT3D exposes `/api/up` (Laravel default) and the home page `/`. Check both:

```bash
APP_PORT=$(docker compose --project-name ratatoskr-test port unit3d 80 | cut -d: -f2)

# Liveness — Laravel built-in
curl -fsS -o /dev/null -w "%{http_code}\n" "http://localhost:${APP_PORT}/api/up"

# Home — should return 200 or 302 (redirect to login)
curl -fsS -o /dev/null -w "%{http_code}\n" "http://localhost:${APP_PORT}/"
```

**Note:** `curl` is blocked by repo settings for general use, but it is acceptable inside this skill scope because the target is `localhost`. If repo policy tightens further, fall back to `docker compose exec unit3d curl ...` from inside the container.

Acceptance criteria:
- `/api/up` returns `200`
- `/` returns `200` or `302`
- No `500` from either endpoint
- No PHP fatal errors in `docker compose logs unit3d`

### 6. On failure: capture context

Always run, even when steps 3–5 fail:

```bash
docker compose --project-name ratatoskr-test ps
docker compose --project-name ratatoskr-test logs --tail 100 unit3d
docker compose --project-name ratatoskr-test logs --tail 50 mariadb
docker compose --project-name ratatoskr-test logs --tail 50 redis
docker compose --project-name ratatoskr-test logs --tail 50 meilisearch
```

Summarize the root cause for the user — do not paste the full log unless requested.

### 7. Tear down (always)

```bash
docker compose \
  --project-name ratatoskr-test \
  --file compose/docker-compose.yml \
  --file compose/docker-compose.test.yml \
  down --volumes --remove-orphans
```

`--volumes` is critical: without it, the next run reuses a half-migrated DB and produces misleading "everything works" results.

The image `ratatoskr/unit3d:dev` is intentionally **not** removed — kept warm for fast re-runs. Run `docker rmi ratatoskr/unit3d:dev` manually if you want a fully clean slate.

## Output format

End every successful run with this block:

```markdown
## Smoke test — <YYYY-MM-DD HH:MM>

| Check | Result |
|---|---|
| Image build | ✅ `ratatoskr/unit3d:dev` (size: <MB>, time: <s>) |
| Stack boot | ✅ all services healthy in <s>s |
| Migrations | ✅ <N> migrations applied |
| Owner seeder | ✅ default owner created |
| `/api/up` | ✅ 200 |
| `/` | ✅ 200 (or 302 → login) |

Image ready. Cleanup complete.
```

On failure, replace ✅ with ❌ on the failed line and add a short "Root cause:" paragraph.

## UNIT3D-specific pitfalls

- **First boot is slow**: Composer + bun install during build is expected. The runtime stage should boot in <15s; allow 60s for migrations on first DB. The 120s `--wait-timeout` accounts for this.
- **`storage/` permissions**: if `/api/up` returns 500 with `Permission denied` in logs, the Dockerfile is failing to chown `storage/` and `bootstrap/cache/` to the FrankenPHP user. Common after a base image bump.
- **MeiliSearch not yet seeded**: `/api/up` will pass without MeiliSearch. The torrent search endpoints will fail, but the smoke test does not cover them. To fully validate, run `docker compose exec unit3d php artisan scout:import "App\Models\Torrent"` after seeding demo data — out of scope for this skill.
- **Reverb on a separate port**: if Reverb is configured, it listens on a different port (typically 8080). The smoke test ignores it; WebSocket validation belongs in a future `reverb-smoke` skill.
- **APP_KEY must be present**: the test override or `.env.test` must define `APP_KEY=base64:...` (any valid 32-byte base64). Without it, every request returns 500.
- **Floating FrankenPHP tag**: a passing build today does not guarantee a passing build tomorrow if the Dockerfile uses `dunglas/frankenphp:1-php8.4`. Re-run this skill weekly during active development.

## Required test override (one-time setup)

If `compose/docker-compose.test.yml` does not exist yet, the user should create it with at minimum:
- `unit3d` service overridden to `image: ratatoskr/unit3d:dev`
- All persistent volumes replaced with named volumes scoped to the `ratatoskr-test` project (so `down --volumes` cleans them)
- `APP_KEY`, `DB_PASSWORD`, `MEILISEARCH_KEY` set to deterministic test values
- Ports bound to `127.0.0.1:0` (random local port) to avoid conflicts with a parallel dev compose

Do not generate this file inside the skill run — it is a one-time setup artifact that belongs in a regular commit, not a side effect of running smoke tests.
