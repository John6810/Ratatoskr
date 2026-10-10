---
name: docker-build-local
description: Build the ratatoskr UNIT3D FrankenPHP image locally and run a smoke test against a minimal Compose stack (MariaDB, Redis, MeiliSearch). Verifies the image builds, the unit3d-migrate one-shot completes (migrate + DatabaseSeeder), and the unit3d service responds on / (UNIT3D v9.2.0 has no /api/up). Use after any change to the Dockerfile, entrypoint, Caddyfile, PHP config, composer/bun lockfiles, or the compose stack. Also use before tagging a release or pushing to ghcr.io. Tears down all resources at the end, even on failure.
allowed-tools: Bash(docker build:*), Bash(docker buildx:*), Bash(docker compose:*), Bash(docker images:*), Bash(docker ps:*), Bash(docker logs:*), Bash(docker inspect:*), Bash(docker exec:*), Bash(docker stop:*), Bash(docker rm:*), Bash(docker network:*), Bash(docker volume ls:*), Bash(grep:*), Bash(rg:*), Bash(cat:*), Bash(sleep:*), Read, Glob
---

# Docker build and local smoke test

Apply after Dockerfile, entrypoint, PHP, Caddy, dependency-lock or Compose changes.
Run from the repository root. Docker with Buildx and Compose v2 is required.

## Build all runtime dependencies

```bash
bash scripts/tests/build-dependencies.sh
docker buildx build --load --platform linux/amd64 --provenance=false \
  -f docker/Dockerfile --target migration -t ratatoskr/unit3d:dev-migration .
docker buildx build --load --platform linux/amd64 --provenance=false \
  -f docker/Dockerfile -t ratatoskr/unit3d:dev .
```

Use the host platform for local tests; CI separately executes both supported
architectures on native runners. Local test tags must never be pushed.
If a build fails, inspect its log and repair the cause before running the stack.

## Run the maintained suite

```bash
bash scripts/tests/compose-smoke.sh
```

The suite owns an isolated random Compose project and always removes its own
containers, networks and volumes. It uses committed test-only fixtures from
`compose/.env.test` and `compose/docker-compose.test.yml`. Never substitute a
real deployment's project, credentials or volumes.

It first verifies immutable source, PHP settings, removed SQL/build tools,
SUID/SGID removal, blocked direct scripts/dotfiles, uncompressed announce replies,
and absence of credential markers in access logs. It then tests fresh database
seeding, owner login/session, CSRF rejection, Livewire search, repeat migrations
without reseeding, and prompt SIGTERM cancellation of initialization waits.

Require `COMPOSE_SMOKE_RESULT=PASS`. On failure inspect the retained command
output, correct the defect and rerun. Do not weaken assertions or retry failed
application checks to obtain a pass. Summarize results and material limits to
the user; local success does not certify production ingress, CSI/CNI or load.
