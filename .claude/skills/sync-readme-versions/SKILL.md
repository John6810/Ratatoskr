---
name: sync-readme-versions
description: Detect drift between the version literals shown in README.md (badges, stack table) and the actual versions pinned in the repo (Chart.yaml appVersion, Dockerfile ARG, docker-compose.yml images, Kustomize image tags). Reports the inconsistencies and proposes the patch. Use after a dependency bump, before tagging a release, or when the README looks suspiciously out of sync. Complementary to check-upstream-versions, which compares the repo to upstream.
allowed-tools: Bash(yq:*), Bash(rg:*), Bash(grep:*), Bash(sed -n:*), Bash(cat:*), Bash(find:*), Read, Glob
---

# Sync README versions

Catch the case where someone bumps a dependency in code but forgets to update the README. The README is the project's first impression — a stale badge or wrong stack table version is a credibility leak.

## When to invoke

- After running `check-upstream-versions` and applying bumps
- Before tagging a release
- When the user asks "sync readme", "is the readme up to date?", "fix versions in README"
- Right after merging a `chore(deps):` PR

## Sources of truth (in priority order)

| Component | Authoritative source | Extract |
|---|---|---|
| UNIT3D | `docker/Dockerfile` `ARG UNIT3D_VERSION` | `rg '^ARG UNIT3D_VERSION=' docker/Dockerfile` |
| UNIT3D (alt) | `helm/unit3d/Chart.yaml` `appVersion` | `yq '.appVersion' helm/unit3d/Chart.yaml` |
| Chart version | `helm/unit3d/Chart.yaml` `version` | `yq '.version' helm/unit3d/Chart.yaml` |
| FrankenPHP | `docker/Dockerfile` base image | `rg '^FROM dunglas/frankenphp' docker/Dockerfile` |
| MariaDB | `compose/docker-compose.yml` image tag | `yq '.services.mariadb.image' compose/docker-compose.yml` |
| Redis | `compose/docker-compose.yml` image tag | `yq '.services.redis.image' compose/docker-compose.yml` |
| MeiliSearch | `compose/docker-compose.yml` image tag | `yq '.services.meilisearch.image' compose/docker-compose.yml` |

If two sources disagree (e.g. Dockerfile says `v9.2.0` and Chart.yaml says `v9.1.7`), **stop and report the conflict first** — do not pick one silently. The fix is to align the code, not the README.

## Workflow

### 1. Extract authoritative versions from code

Run the commands above. Skip silently if a file does not yet exist (early stages of the project).

### 2. Extract versions claimed by README.md

```bash
# Badges (shields.io style)
rg -o 'img\.shields\.io/badge/[^)]+' README.md

# Stack table — find lines with version-looking literals
rg -n '^\| .* \|.*v?[0-9]+\.[0-9]+' README.md
```

### 3. Compare

For each component, compare README claim vs authoritative source. Build a single diff table.

### 4. Report

```markdown
## README sync — <YYYY-MM-DD>

| Component | README says | Code says | Status |
|---|---|---|---|
| UNIT3D badge | v9.2.0 | v9.2.0 | ✅ |
| UNIT3D in Stack table | v9.1.7 | v9.2.0 | ❌ outdated |
| FrankenPHP badge | 1-php8.4 | 1-php8.4 | ✅ |
| MariaDB row | 11 | 11 | ✅ |
| MeiliSearch row | latest stable | v1.21.0 | ⚠️ README is vaguer than code |

### Patches to apply
- `README.md:18` — badge UNIT3D v9.1.7 → v9.2.0
- `README.md:42` — Stack table row UNIT3D v9.1.7 → v9.2.0

### Notes
- MeiliSearch: README intentionally says "latest stable" (per CLAUDE.md "verify before pinning"). If you want the README to mirror the actual pin, update the table row to v1.21.0.
```

Do not edit the README inside the skill — show the patches, let the user (or a separate Edit) apply them.

## Pitfalls

- **README intentionally vague**: `CLAUDE.md` says MeiliSearch should be marked "latest stable (verify)" in the doc but pinned strictly in code. Don't flag this as drift; flag it as a deliberate choice.
- **Badge URLs are URL-encoded**: a version `v9.2.0` in a shields.io badge is `v9.2.0` (no encoding) but a hyphen becomes `--`. Read the raw URL, don't render it.
- **Multiple READMEs**: `README.md` at root, `compose/README.md`, `helm/unit3d/README.md`. Sync them all if they exist — sub-READMEs drift even more than the root one.
- **`appVersion` vs Dockerfile ARG**: both should equal the UNIT3D upstream version. If they disagree, the chart will pull a different image than the build produces. Always treat the Dockerfile as authoritative for what gets built; treat `appVersion` as documentation of intent.
- **Chart `version` is independent**: it bumps on every chart change, even when UNIT3D doesn't. Don't try to align it with `appVersion` — they are two different concepts.
