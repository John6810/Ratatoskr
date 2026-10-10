# Application security dependencies

UNIT3D v9.2.0 remains the application source release. Its PHP source and
`composer.json` are unchanged. Ratatoskr maintains a reviewed Composer lock
within those upstream constraints because the released lock has known security
findings. This image is not dependency-identical to the upstream release.

The Docker build checks both upstream Composer files against `upstream.sha256`
before applying `v9.2.0/composer.lock`. An unqualified release or changed upstream
manifest fails closed. Builds run `composer install`, platform checks, and a
production dependency audit; they do not run `composer update`. Development
packages are neither installed nor copied into the runtime.

Security refresh on 2026-10-10:

| Package | Upstream lock | Maintained lock |
|---|---|---|
| guzzlehttp/guzzle | 7.10.0 | 7.15.5 |
| laravel/framework | 12.40.2 | 12.69.3 |
| league/commonmark | 2.7.1 | 2.10.3 |
| symfony/dom-crawler | 6.4.25 | 6.4.44 |
| symfony/http-foundation | 7.4.0 | 7.4.20 |
| symfony/mailer | 7.3.3 | 7.4.19 |
| symfony/mime | 7.4.0 | 7.4.19 |
| livewire/livewire | 3.6.4 | 3.8.10 |
| psy/psysh | 0.12.10 | 0.12.24 |

Eight related runtime dependencies also changed through Composer's resolver;
the checked-in lock records every version, source reference and distribution.
The production Composer audit is clean. Development-only dependencies retain
the upstream lock and are outside this runtime qualification.

## Refreshing the lock

Build the toolchain separately so a future audit failure cannot prevent repair:

```bash
docker build --target php-toolchain -f docker/Dockerfile -t ratatoskr/php-toolchain .
```

In a temporary directory, obtain the chosen upstream `composer.json` and
`composer.lock`, verify the release, and save their SHA-256 digests before any
changes. Mount that directory into the toolchain and run a targeted update:

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -e COMPOSER_HOME=/tmp/composer -v "$PWD:/work" -w /work \
  --entrypoint composer ratatoskr/php-toolchain \
  update guzzlehttp/guzzle laravel/framework league/commonmark \
  symfony/dom-crawler symfony/http-foundation symfony/mailer symfony/mime \
  livewire/livewire psy/psysh \
  --with-all-dependencies --minimal-changes --no-install --no-scripts --no-dev
```

Review the resulting diff against upstream, audit production dependencies, and
copy the lock and original checksums into `docker/security/<UNIT3D_VERSION>/`.
Do not alter upstream constraints or disable advisory blocking to force a solve.
Qualify the rebuilt image with the Compose and Kubernetes suites described in
[the test guide](../../scripts/tests/README.md), including an existing database
upgrade and authenticated browser session. Keep the Trivy gate enabled.

## FrankenPHP

Builder and runtime are the official FrankenPHP 1.13.0 / PHP 8.4 images, pinned
by multi-platform digest. The builder contains the source, locked Caddy module
set, Go toolchain and matching libphp. Ratatoskr updates only
`golang.org/x/net` from 0.59.0 to 0.60.0 to fix CVE-2026-78669, verifies module
checksums, and rebuilds with upstream `go.sh` and its original linker settings.
No modules are removed. The runtime receives only the new binary and restores
its bind capability; the Go compiler stays in the builder.

Update both image digests together to preserve the PHP ABI. Inspect
`frankenphp build-info`, scan the resulting runtime, and build both amd64 and
arm64. Remove the override only after a newer upstream image contains the fix
and passes the same checks. Custom-build reference:
[FrankenPHP Docker documentation](https://frankenphp.dev/docs/docker/).

## Runtime and dependency images

`docker/Dockerfile` produces two images from the same upstream application:
`runtime` serves HTTP, queues and scheduling without MariaDB CLI libraries;
`migration` retains the CLI needed by Laravel schema imports. Always update both
together. Source and Caddy configuration are root-owned; only designated storage
and cache paths are writable. PHP suppresses version disclosure and exception
arguments. Caddy refuses dotfiles and direct PHP-like script URLs, keeps announce
responses uncompressed, and removes URI/headers from access logs.

Both Debian runtime stages upgrade all available distribution packages, including
XZ 5.8.1-1+deb13u2. Base digests remain pinned; installed security package versions
can advance during a rebuild. Record and deploy resulting image digests.
`docker/dependencies/Dockerfile` preserves MariaDB 11.8.9, Redis 7.4.11 and
MeiliSearch 1.43.1 data formats while updating their OS packages. MariaDB's gosu
1.19 helper is rebuilt from a verified upstream commit with a current Go toolchain
and fixed user/sys modules. MeiliSearch runs as UID 65532. A newer MeiliSearch
feature release requires a separately tested index migration.

Backup tooling uses the same pinned MariaDB base. Its Restic source build also
updates OpenTelemetry SDK to 1.45.0 for
[CVE-2026-81870](https://github.com/open-telemetry/opentelemetry-go/security/advisories/GHSA-8wmf-6v46-5gfg).

## Publication gate

Every PR builds and executes all six images on native amd64 and arm64 runners.
Trivy retains the complete OS/library inventory, including unfixed findings and
UNKNOWN severity. `scripts/security/check-image.py` rejects every available fix
at **any severity** and fails on missing OS scan results. No ignore list or VEX
suppression was added. CI refreshes OS package layers instead of reusing stale
apt/apk resolution. Composer's production audit remains mandatory.

Main/tag publication requires both these image checks and the reusable manifest,
secret scan, Compose, Helm, RWX and physical backup/restore qualification. It
builds multi-platform images with SBOM/provenance and signs their manifest digest.
PRs never publish images. New dependency and migration repositories must exist
from an authorized main/tag publication, or be built and loaded into a local
cluster explicitly; unmerged PR image tags are not registry releases.

The [assessment](../../docs/security-assessment.md) records remaining distribution
findings and operational limits. A passing available-fix gate does not certify
that the image has no vulnerabilities.
