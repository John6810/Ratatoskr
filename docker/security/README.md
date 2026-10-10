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

UNIT3D pull requests build and scan amd64 and arm64 on matching native runners.
The arm64 job also executes PHP and FrankenPHP from the resulting image. This
avoids lengthy QEMU compilation of PHP/CGO during review. Main/tag publication
still builds the multi-platform manifest and signs it; PRs never publish images.
