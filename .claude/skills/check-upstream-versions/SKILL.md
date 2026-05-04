---
name: check-upstream-versions
description: Check upstream versions of UNIT3D, FrankenPHP, MeiliSearch, MariaDB, Redis and Laravel against what is currently pinned in the repository (CLAUDE.md table, Dockerfile ARG, compose, Helm Chart.yaml, Kustomize image tags). Use whenever the user asks about versions being up to date, before pinning a new dependency, before tagging a release, or when planning an upgrade. Reports an outdated/up-to-date table with concrete bump suggestions and AGPL-safe upgrade paths.
allowed-tools: Bash(gh api:*), Bash(grep:*), Bash(rg:*), Bash(cat:*), Bash(find:*), Bash(yq:*), Bash(jq:*), Read, Glob
---

# Check upstream versions

Compare versions pinned in this repository against the latest upstream releases for every component of the UNIT3D stack. Report a clean diff and propose concrete bumps.

## When to invoke

- "Are we up to date?", "Check versions", "What's outdated?"
- Before pinning a new image or tag
- Before tagging a release
- When the user signals an upgrade intention
- Any time CLAUDE.md, the Dockerfile, or a manifest is about to be modified with a version literal

## Components to check

| Component | Upstream source | API call |
|---|---|---|
| UNIT3D | `HDInnovations/UNIT3D` | `gh api repos/HDInnovations/UNIT3D/releases/latest` |
| FrankenPHP | `php/frankenphp` | `gh api repos/php/frankenphp/releases/latest` |
| MeiliSearch | `meilisearch/meilisearch` | `gh api repos/meilisearch/meilisearch/releases/latest` |
| Laravel | endoflife.date | `WebFetch https://endoflife.date/api/laravel.json` |
| MariaDB | endoflife.date | `WebFetch https://endoflife.date/api/mariadb.json` |
| Redis | endoflife.date | `WebFetch https://endoflife.date/api/redis.json` |
| PHP | endoflife.date | `WebFetch https://endoflife.date/api/php.json` |

`curl` and `wget` are denied by repo settings — always use `gh api` or `WebFetch`.

## Workflow

### 1. Read the currently pinned versions

Search the repo for version literals. Sources of truth, in order:

```bash
# CLAUDE.md stack table (authoritative for documentation)
rg -n 'v[0-9]+\.[0-9]+\.[0-9]+' CLAUDE.md

# Dockerfile ARGs (authoritative for the build)
rg -n '^ARG\s+\w+_VERSION' docker/Dockerfile

# Compose images
rg -n 'image:\s*\S+' compose/docker-compose.yml

# Helm chart
[ -f helm/unit3d/Chart.yaml ] && yq '.appVersion, .version, .dependencies' helm/unit3d/Chart.yaml

# Kustomize image transformers
rg -nA1 'images:' kustomize/base/**/kustomization.yaml 2>/dev/null
```

If a file does not exist yet at the current stage of the project, skip it silently — do not error out.

### 2. Fetch latest upstream versions

Run these in parallel where possible:

```bash
gh api repos/HDInnovations/UNIT3D/releases/latest --jq '{tag: .tag_name, date: .published_at, name: .name}'
gh api repos/php/frankenphp/releases/latest --jq '{tag: .tag_name, date: .published_at}'
gh api repos/meilisearch/meilisearch/releases/latest --jq '{tag: .tag_name, date: .published_at}'
```

For Laravel/MariaDB/Redis/PHP, use `WebFetch` against `https://endoflife.date/api/<product>.json` and extract the `latest` field of the most recent supported cycle.

### 3. Compare and report

Output a single markdown table. Format strictly:

```markdown
## Version check — <YYYY-MM-DD>

| Component | Pinned | Latest upstream | Status | Notes |
|---|---|---|---|---|
| UNIT3D | v9.2.0 | v9.2.0 | ✅ up to date | — |
| FrankenPHP (image tag) | 1-php8.4 | 1.11.3 / php 8.4 | ✅ tag still valid | floating tag, rebuild gets latest |
| MeiliSearch | latest stable | v1.21.0 | ⚠️ pin recommended | pin to v1.21.x for reproducibility |
| MariaDB | 11 | 11.6.2 | ✅ tag still valid | LTS until 2028 |
| Redis | 7 | 7.4.2 | ✅ tag still valid | — |
| Laravel (via UNIT3D) | 12.x | 12.x | ✅ up to date | UNIT3D upstream controls this |

### Suggested bumps
- None — stack is current.

### Files to update if bumping
- `CLAUDE.md` — Stack table
- `docker/Dockerfile` — `ARG UNIT3D_VERSION`
- `compose/docker-compose.yml` — service `image:` lines
- `helm/unit3d/Chart.yaml` — `appVersion`
- `kustomize/base/**/kustomization.yaml` — `images:` block
- `README.md` — badges and Stack table
```

### 4. Flag breaking changes

If a major version bump is detected (e.g. UNIT3D v9 → v10, FrankenPHP 1.x → 2.x, MeiliSearch 1.x → 2.x), do not silently propose the bump. Add a `### Breaking changes` section that:

- Links to the upstream changelog / release notes
- Lists known migration steps from the release notes
- Recommends a feature branch + manual review

For UNIT3D specifically, check the release notes for database migration requirements (`php artisan migrate`), config changes in `.env.example`, and dependency bumps that affect the Dockerfile (PHP version, extensions).

## Pitfalls

- **GitHub API rate limit**: 60/h unauthenticated, 5000/h with `gh auth login`. If rate-limited, fall back to `WebFetch` on the public release page.
- **MeiliSearch GitHub releases mix `latest` and `enterprise` tags**: filter on the `latest` tag, not the `enterprise-*` tags.
- **FrankenPHP image tag vs. binary version**: the Docker tag `1-php8.4` is a floating tag tracking the latest 1.x with PHP 8.4. The repo pins the floating tag; the binary version reported by upstream is more granular. Both being current means: report ✅ and mention that a rebuild pulls the latest.
- **Laravel version is controlled by UNIT3D upstream**, not by this repo. Do not propose bumping Laravel independently.
- **`endoflife.date` is the right source for MariaDB/Redis/PHP** because Docker Hub tags lie (`latest` floats unpredictably). Verify the cycle is still supported (`eol` field in the future).
- **Never propose downgrades**, even if the repo pins a version newer than what `endoflife.date` lists as `latest` (it lags by a few days).

## After running

If the user agrees to a bump, the next step is to update every file listed in "Files to update if bumping" in a single atomic commit:

```
chore(deps): bump <component> to <new-version>
```

Do not bundle multiple component bumps in one commit unless they are functionally tied (e.g. UNIT3D bump that requires a PHP extension change in the Dockerfile).
