# Upstream PRs ratatoskr depends on

This file tracks pull requests against [HDInnovations/UNIT3D](https://github.com/HDInnovations/UNIT3D) that ratatoskr's roadmap or operating posture depends on. Each entry names the PR (or "not yet filed"), the ratatoskr feature it unblocks, and the current status. The list is short by design — only items that move the needle on a release.

ratatoskr's policy: vanilla UNIT3D, never forked. When ratatoskr needs upstream behavior to change, the answer is an upstream PR — not a local patch set that diverges over time. This file makes that policy concrete by listing what we actually depend on.

## Format

Each entry follows this shape:

```
### <short title>
- **Status**: not filed | open #NNNN | merged in vX.Y.Z | rejected
- **Unblocks**: <ratatoskr feature> in <release>
- **Why**: <one paragraph: what behavior changes upstream and why ratatoskr cannot work around it locally>
- **Workaround at v<X.Y>**: <how ratatoskr currently copes>
- **Last reviewed**: <YYYY-MM-DD>
```

Edit-on-touch rule: when the PR moves, update the status and the date in the same commit that consumes the change.

## Active dependencies

### Storage-aware writes for image-handling controllers

- **Status**: not yet filed
- **Unblocks**: ROADMAP v0.4 — fully stateless `unit3d-app` (`replicas: N` works on any cluster, no PVC for image disks)
- **Why**: UNIT3D v9.2.0 controllers write to most image disks via `Storage::disk('<name>')->path($filename)` followed by Intervention Image's `Image::make(...)->save($path)` (or Symfony's `UploadedFile::move($path, ...)`). Both calls write to a local filesystem path. On an S3 driver, `->path()` raises `LogicException: This driver does not support retrieving paths.`, and `->save()` would write to a local path the S3 disk cannot read back. The fix is mechanical: replace each `->path()` + `->save()` pair with `Storage::disk(...)->put($filename, (string) $image->encode(...))`. Affected controllers per the v9.2.0 audit (see [ADR-0002](./adr/0002-storage-strategy-unit3d-storage.md) Disk inventory):
  - `app/Http/Controllers/User/UserController.php` — `user-avatars`, `user-icons` (non-GIF branches)
  - `app/Http/Controllers/TorrentController.php` — `torrent-covers`, `torrent-banners`
  - `app/Http/Controllers/Staff/ArticleController.php` — `article-images`
  - `app/Http/Controllers/Staff/CategoryController.php` — `category-images`
  - `app/Http/Controllers/PlaylistController.php` — `playlist-images`
  - `app/Helpers/TorrentTools.php` — `temporary-nfos` (`UploadedFile::move`)
- **Workaround at v0.3**: hybrid storage. The three Storage-aware disks (`torrent-files`, `subtitle-files`, `attachment-files`) move to S3; image disks stay on PVC, capping `unit3d-app` at single-replica unless the cluster has an RWX storage class. Documented in [ADR-0002](./adr/0002-storage-strategy-unit3d-storage.md).
- **Last reviewed**: 2026-05-06

### Env-driven driver configuration in `config/filesystems.php`

- **Status**: not yet filed
- **Unblocks**: ratatoskr's S3 swap without a ConfigMap-mounted `config/filesystems.php` override
- **Why**: every disk in `config/filesystems.php` at v9.2.0 hardcodes `'driver' => 'local'`. Nothing reads from `env()`. Operators cannot flip a disk to `s3` via environment variables alone. The fix is to wrap each disk's `driver` (and connection details) in `env('FILESYSTEM_DRIVER_<DISK>', 'local')` style indirection, matching Laravel-default filesystems.php.
- **Workaround at v0.3**: ratatoskr ships a replacement `config/filesystems.php` mounted via ConfigMap volume at `/var/www/html/config/filesystems.php`. The image stays byte-identical; the override is deployment-time, not a fork. Maintenance burden: review the ratatoskr override against new upstream `filesystems.php` on each UNIT3D bump (a five-minute diff). Documented in [ADR-0002](./adr/0002-storage-strategy-unit3d-storage.md) Decision section.
- **Last reviewed**: 2026-05-06

### `php artisan key:rotate` (or equivalent)

- **Status**: not yet filed; depends on Laravel framework support more than UNIT3D specifically
- **Unblocks**: planned `APP_KEY` rotation procedure in ratatoskr's operator guide
- **Why**: rotating Laravel's `APP_KEY` corrupts every encrypted column, every signed URL, and every encrypted session cookie unless old ciphertexts are re-encrypted under the new key. Laravel 12 itself ships no `key:rotate` command; UNIT3D inherits the absence. Rotation today requires a custom Artisan command that walks every model with `encrypted` casts and re-encrypts each row in a transaction.
- **Workaround at v0.3**: ratatoskr documents `APP_KEY` as generated once and never rotated. If a compromise occurs, the operator follows a manual procedure outside ratatoskr's automation. Documented in [ADR-0004](./adr/0004-secret-management.md).
- **Last reviewed**: 2026-05-06

## Resolved (kept for archaeology)

_(none yet — first entry will move here when its upstream PR merges.)_

## Conventions

- **Don't add an entry just because we'd like upstream to be different.** Entries here represent dependencies that gate a ratatoskr roadmap milestone. Nice-to-haves go elsewhere.
- **Update the entry on every release of UNIT3D**, even if only to bump the "Last reviewed" date. Stale entries rot.
- **When a PR is filed**, update Status to `open #NNNN` and link from the PR description back to this file so upstream maintainers see the dependency context.
