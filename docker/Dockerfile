# syntax=docker/dockerfile:1.7

# Build context MUST be the repo root so `COPY docker/Caddyfile` resolves:
#   docker build -f docker/Dockerfile -t ratatoskr/unit3d:dev .
#
# Pinned floating tags. For reproducible release builds, append a digest:
#   FROM dunglas/frankenphp:1-php8.4@sha256:<digest> AS ...
ARG FRANKENPHP_VERSION=1-php8.4
ARG UNIT3D_VERSION=v9.2.0

# =============================================================================
# Stage 1 — builder: fetch UNIT3D, install Composer + Bun deps, build assets.
# Holds compilers, git, composer, bun. Never reaches the runtime image.
# =============================================================================
FROM dunglas/frankenphp:${FRANKENPHP_VERSION} AS builder

ARG UNIT3D_VERSION

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_NO_INTERACTION=1 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Build-time PHP extensions (Composer needs intl/zip; UNIT3D extensions are
# resolved here too so post-install scripts like `package:discover` succeed).
RUN install-php-extensions \
        @composer \
        bcmath \
        exif \
        gd \
        intl \
        pcntl \
        pdo_mysql \
        redis \
        sodium \
        zip

# Bun for frontend asset build (UNIT3D ships a bun.lockb + Vite pipeline).
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -s /root/.bun/bin/bun /usr/local/bin/bun

WORKDIR /build

# Pinned UNIT3D source. Tag drives the image — never hardcoded in the URL.
RUN git clone --depth 1 --branch "${UNIT3D_VERSION}" \
        https://github.com/HDInnovations/UNIT3D.git .

# --no-scripts skips Laravel's package:discover post-autoload-dump hook, which
# boots the framework and chokes on env-driven config (e.g. parse_url(env('APP_URL'))
# in config/secure-headers.php) when no .env is present at build time.
# package:discover runs at first artisan invocation inside unit3d-migrate.
RUN composer install --no-dev --optimize-autoloader --no-scripts --no-interaction --prefer-dist

# FrankenPHP worker mode needs a worker entrypoint that calls
# frankenphp_handle_request() in a loop — stock public/index.php doesn't.
# Octane ships the right stub; copy it into public/ so the Caddyfile can
# point at it. We avoid `php artisan octane:install` because it mutates
# .gitignore and downloads a separate frankenphp binary we don't need.
RUN cp vendor/laravel/octane/src/Commands/stubs/frankenphp-worker.php \
       public/frankenphp-worker.php

RUN bun install --frozen-lockfile \
    && bun run build \
    && rm -rf node_modules

# Strip dev cruft so the runtime stage copies only what the app needs.
RUN rm -rf .git .github tests phpunit.xml .editorconfig .styleci.yml \
           .gitattributes .gitignore docker-compose.yml

# =============================================================================
# Stage 2 — runtime: FrankenPHP worker mode. No compilers, no composer, no bun.
# =============================================================================
FROM dunglas/frankenphp:${FRANKENPHP_VERSION} AS runtime

ARG UNIT3D_VERSION

LABEL org.opencontainers.image.source="https://github.com/john6810/ratatoskr" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.title="ratatoskr-unit3d" \
      org.opencontainers.image.description="UNIT3D Community Edition on FrankenPHP worker mode" \
      org.opencontainers.image.version="${UNIT3D_VERSION}"

# SERVER_NAME defaults to :80 (plain HTTP). Override at deploy time with a
# real hostname (e.g. SERVER_NAME=tracker.example.org) to enable Caddy's
# automatic Let's Encrypt TLS — only relevant when the container is the
# edge. In K8s / behind Traefik, keep :80 and terminate TLS upstream.
#
# APP_ENV / APP_DEBUG are intentionally NOT baked in. Set them via the
# operator's .env, ConfigMap, or Helm values — never hardcoded in the image.
ENV DEBIAN_FRONTEND=noninteractive \
    SERVER_NAME=":80" \
    FRANKENPHP_CONFIG="worker ./public/frankenphp-worker.php"

# mariadb-client is required by Laravel's `migrate` when a schema dump exists
# at database/schema/mysql-schema.sql (UNIT3D v9.2.0 ships one). Laravel shells
# out to `mysql ... < mysql-schema.sql` for fast fresh installs. Also useful
# for operators debugging the DB inside the container.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        mariadb-client \
    && rm -rf /var/lib/apt/lists/*

RUN install-php-extensions \
        bcmath \
        exif \
        gd \
        intl \
        opcache \
        pcntl \
        pdo_mysql \
        redis \
        sodium \
        zip

# Production php.ini (opcache enabled, sane memory_limit, no display_errors).
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

WORKDIR /app

# Application code, owned by www-data from the start (no post-COPY chown layer).
COPY --chown=www-data:www-data --from=builder /build /app

# Caddyfile is the source of truth for the server config. Auto-generated config
# is not used in production. The file lives at docker/Caddyfile in this repo.
COPY --chown=www-data:www-data docker/Caddyfile /etc/caddy/Caddyfile

# The dunglas/frankenphp Debian image already sets cap_net_bind_service on
# /usr/local/bin/frankenphp — no extra setcap call needed. We just ensure the
# Laravel writable trees and Caddy state dirs are owned by www-data.
RUN chown -R www-data:www-data \
        /app/storage \
        /app/bootstrap/cache \
        /data/caddy \
        /config/caddy

USER www-data

EXPOSE 80 443 443/udp

# UNIT3D v9.2.0 has no native health endpoint (verified upstream: no /up —
# legacy bootstrap with no withRouting(health:); no Health/Status/Ping
# controller; no spatie/laravel-health package). `/` exercises the full
# middleware stack and returns 302 -> /login for unauthenticated probes.
# curl -f succeeds on 2xx and 3xx, fails on 4xx/5xx, so a healthy app
# returns success without rendering Blade or hitting the DB.
# Caveat: session middleware touches Redis — this probe covers Redis liveness.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS --max-time 4 -o /dev/null http://127.0.0.1/ || exit 1

# Required runtime env vars (set via .env, ConfigMap, or Secret):
#   APP_KEY=base64:...                generated once with `php artisan key:generate --show`
#   APP_ENV, APP_DEBUG, APP_URL
#   DB_HOST, DB_DATABASE, DB_USERNAME, DB_PASSWORD
#   REDIS_HOST, REDIS_PASSWORD
#   MEILISEARCH_HOST, MEILISEARCH_KEY
#   DEFAULT_OWNER_NAME, DEFAULT_OWNER_EMAIL, DEFAULT_OWNER_PASSWORD   (first boot only)
#
# Migrations are NOT run here. They run as a Helm pre-install hook or a
# Kustomize init Job. See kustomize/base/job-migrate.yaml / chart hooks.
