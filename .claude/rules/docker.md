---
applies-to:
  - docker/**
  - compose/**
  - .dockerignore
---

# Docker & Compose rules

> Active when working under `docker/`, `compose/`, or on `.dockerignore`. Complements `00-global.md`.

## Image build

- **Multi-stage builds only.** A `builder` stage that holds composer + bun + git, and a `runtime` stage that holds only what the app needs at runtime. Single-stage Dockerfiles for this project are rejected.
- **Pin the base image with a tag, not `:latest`.** `dunglas/frankenphp:1-php8.4` is the floating tag we accept (rebuilds get latest 1.x with PHP 8.4). For reproducible release builds, append a digest pin `@sha256:...`.
- **`UNIT3D_VERSION` exposed as a build ARG**, default to the current target (`v9.2.0`). Never hardcode it inside `RUN git clone`.
- **`composer install --no-dev --optimize-autoloader --no-interaction`** in the builder stage — never the runtime stage. The runtime never sees composer.
- **`bun install --frozen-lockfile`** then `bun run build`. Never `bun install` without the flag (silent lockfile drift).
- **Required PHP extensions**: `pdo_mysql`, `redis`, `intl`, `bcmath`, `gd`, `zip`, `exif`, `opcache`, `pcntl`, `sodium`. Install via FrankenPHP's `install-php-extensions` helper.
- **`apt-get install` always with `--no-install-recommends`** and followed by `rm -rf /var/lib/apt/lists/*` in the same `RUN` to keep the layer clean.
- **`COPY --chown=www-data:www-data`** when copying app files into the runtime stage. Never `COPY` then `RUN chown` (extra layer, root-owned files briefly).
- **Permissions on `storage/` and `bootstrap/cache/`** must be writable by the FrankenPHP user. The Dockerfile sets this; do not rely on volume-time chown at runtime.

## Image surface

- **Run as non-root.** Set `USER` in the runtime stage. The FrankenPHP image already provides a usable non-root user — use it.
- **`HEALTHCHECK` in the Dockerfile.** UNIT3D v9.2.0 has no native health endpoint (verified upstream: no `/up`, no Health/Status controller, no spatie/health). Probe `/` with `curl -fsS --max-time 4` — `curl -f` accepts 200 and 302 (the unauthenticated redirect to `/login`) and fails on 4xx/5xx. Compose-level healthchecks are also required (see below). If a future UNIT3D release ships a real health route, switch to it and update this rule in the same commit.
- **OCI labels** in the runtime stage:
  - `org.opencontainers.image.source=https://github.com/john6810/ratatoskr`
  - `org.opencontainers.image.licenses=AGPL-3.0-or-later`
  - `org.opencontainers.image.title=ratatoskr-unit3d`
  - `org.opencontainers.image.version=<UNIT3D_VERSION>`
- **`.dockerignore` mandatory** at the root of the build context. Excludes at minimum: `.git`, `.github`, `.claude`, `kustomize`, `helm`, `docs`, `terraform`, `*.md`, `node_modules`, `vendor`, `.env*`.
- **Never `COPY .env`.** Even by accident. The `.dockerignore` enforces it; double-check on every Dockerfile change.

## Compose

- **Every service has a `healthcheck`.** UNIT3D depends on MariaDB + Redis + MeiliSearch being ready; without healthchecks, the app boots faster than the DB and migrations fail.
- **`depends_on` with `condition: service_healthy`** for the unit3d service. `depends_on` without a condition only waits for the container to start, not be ready.
- **Named volumes**, not bind mounts, for data. Bind mounts have OS-specific permission gotchas that bite operators.
- **No port published on `0.0.0.0` in committed compose files.** Use `127.0.0.1:8080:80` for local-only by default. Production exposure happens at the reverse-proxy layer, not the compose layer.
- **`.env.example` always present** alongside `docker-compose.yml`. Real values use `CHANGEME` placeholder.
- **`restart: unless-stopped`** for long-running services in production-shaped compose. Avoid `restart: always` which loops on broken configs forever.

## FrankenPHP specifics

- **Worker mode enabled** via `FRANKENPHP_CONFIG=worker ./public/index.php` (or equivalent in the Caddyfile). The whole point of choosing FrankenPHP is the worker.
- **Caddyfile lives in `docker/Caddyfile`**, copied into the image. Don't rely on FrankenPHP's auto-generated config for production.
- **TLS termination** is the deployer's responsibility (Traefik, ingress, or external LB). Inside the container, FrankenPHP listens on plain HTTP unless explicitly configured for TLS in a single-host scenario.

## Hard rules

- **Never run `php artisan migrate` in the entrypoint of the main app pod.** Migrations are an init container (Kustomize) or pre-install hook (Helm).
- **Never write user-uploaded content to the image.** Avatars, banners, `.torrent` files go to a volume or S3-compatible storage. Otherwise the image bloats forever.
- **Never include build-time secrets** (`ARG GITHUB_TOKEN=...`). Use BuildKit secrets if needed, never `ARG` for sensitive values.
- **Test every Dockerfile change with the `docker-build-local` skill** before suggesting a commit.