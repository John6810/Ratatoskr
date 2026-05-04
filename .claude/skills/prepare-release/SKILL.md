---
name: prepare-release
description: Prepare a ratatoskr release. Bumps version literals across the repo (Chart.yaml, values, README badges, CLAUDE.md stack table), generates a CHANGELOG entry from Conventional Commits since the last tag, and produces release notes ready for `gh release create`. Does not tag or push — the user runs the final commands. Use when the user says "prep v0.X", "tag a release", "release prep", "make release notes".
allowed-tools: Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(git tag:*), Bash(git branch:*), Bash(yq:*), Bash(rg:*), Bash(grep:*), Bash(sed -n:*), Bash(cat:*), Bash(find:*), Read, Glob
---

# Prepare release

Bundle every release prep step into one deterministic flow. Output a single PR-ready summary the user can review before tagging.

## When to invoke

- "Prepare release v0.X", "release prep", "tag v0.X"
- Before any `git tag` or `gh release create`
- Right after merging the last feature PR into `main` for a new minor

## Pre-flight

```bash
test -f CLAUDE.md || { echo "Run from repo root"; exit 1; }
git rev-parse --abbrev-ref HEAD
git status --short   # must be clean
git tag --list 'v*' --sort=-v:refname | head -5
```

If working tree is dirty, stop and tell the user. Releases must be cut from a clean tree on `main`.

## Workflow

### 1. Determine the new version

Ask the user (or take from prompt) which version is being prepped (e.g. `v0.2.0`). Validate it follows semver and is greater than the latest tag.

Cross-check against the project roadmap in CLAUDE.md / README — `v0.2.0` should match the "Hardening Compose" milestone, not be invented.

### 2. Run dependency checks first

Trigger `check-upstream-versions` mentally (or refer the user to run it) and confirm the stack table is current. **Never tag a release with stale versions.**

For Helm release also trigger `helm-lint`. For Kustomize also trigger `kustomize-validate`. For Docker also trigger `docker-build-local`. The user runs these — do not chain them silently.

### 3. Collect commits since last tag

```bash
LAST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
git log "${LAST_TAG}..HEAD" --pretty=format:'%s|%h' --no-merges
```

If there is no previous tag (first release), use the initial commit.

### 4. Group by Conventional Commit type

Parse each commit subject:

| Prefix | CHANGELOG section |
|---|---|
| `feat:`, `feat(scope):` | ✨ Features |
| `fix:`, `fix(scope):` | 🐛 Fixes |
| `docs:` | 📚 Docs |
| `chore(deps):` | ⬆️ Dependencies |
| `chore:`, `refactor:`, `style:` | 🔧 Maintenance |
| `breaking!:` or footer `BREAKING CHANGE:` | ⚠️ Breaking |

Skip commits that don't match the convention rather than guessing — flag them at the end so the user can amend or pre-tag squash.

### 5. Bump version literals

List every file containing the previous version, then propose the patch (do not edit silently):

```bash
rg -l "${LAST_TAG#v}" --type-add 'helm:*.yaml' -t md -t helm -t yaml
```

Files that typically need a bump for this project:

- `helm/unit3d/Chart.yaml` → `version` (chart version, always bumped) and `appVersion` (UNIT3D version, bumped only on UNIT3D upgrade)
- `README.md` → version badge if any
- `CHANGELOG.md` → new entry at the top
- `CLAUDE.md` → only if the UNIT3D stack version changed

Show the user the exact diffs before they apply.

### 6. Render CHANGELOG entry

Append a new section at the top of `CHANGELOG.md`:

```markdown
## [v0.2.0] — YYYY-MM-DD

### ✨ Features
- Add Reverb WebSocket service to Compose stack ([abc1234](https://github.com/john6810/ratatoskr/commit/abc1234))

### 🐛 Fixes
- Correct storage/ permissions on FrankenPHP runtime stage ([def5678](...))

### ⬆️ Dependencies
- Bump UNIT3D to v9.2.0
- Bump MeiliSearch to v1.21.0

### ⚠️ Breaking
- (none)

[v0.2.0]: https://github.com/john6810/ratatoskr/compare/v0.1.0...v0.2.0
```

### 7. Render release notes

Same content as the CHANGELOG entry, plus a one-paragraph upgrade summary at the top tailored for `gh release create`. Save to `/tmp/release-notes-<version>.md` for the user to review.

### 8. Output the final command list

Do not execute — print for the user to run:

```bash
# 1. Commit the bumps
git add CHANGELOG.md helm/unit3d/Chart.yaml README.md CLAUDE.md
git commit -m "chore(release): v0.2.0"

# 2. Tag and push
git tag -a v0.2.0 -m "ratatoskr v0.2.0"
git push origin main --tags

# 3. Create the GitHub release (requires gh auth)
gh release create v0.2.0 \
  --title "ratatoskr v0.2.0" \
  --notes-file /tmp/release-notes-v0.2.0.md
```

## Output format

```markdown
## Release prep — v0.2.0

| Check | Status |
|---|---|
| Working tree clean | ✅ |
| Last tag | v0.1.0 (2026-04-12) |
| Commits since | 23 (18 conventional, 5 non-conventional) |
| Upstream versions current | ✅ (verified) |
| Files needing version bump | 4 |
| CHANGELOG entry | drafted |
| Release notes | written to /tmp/release-notes-v0.2.0.md |

### Non-conventional commits to review
- `wip` (`a1b2c3d`)
- `update` (`e4f5g6h`)

### Next steps
[the 3 commands above]
```

## Pitfalls

- **Two version literals in `Chart.yaml`**: `version` (chart, always bumped) vs `appVersion` (UNIT3D, only bumped on UNIT3D upgrade). Confusing them produces a chart that looks released but pulls the wrong UNIT3D image.
- **Floating tags in image references**: if any manifest pins `:latest` or `:1-php8.4`, document it in the release notes. Operators upgrading from an older release may end up running a different runtime than tested.
- **Breaking changes are often silent**: a `chore(deps)` bump of MariaDB or PHP can break operators. If the dep bump crosses a major, label it `feat!:` or add a `BREAKING CHANGE:` footer in the original commit, or upgrade it manually in this release's CHANGELOG.
- **Never tag from a feature branch**: tag `main` only. Mixing release tags into feature branches makes upgrade paths impossible to audit.
- **CHANGELOG.md is append-at-top**: newest version first. Some tools read top-down and stop at the first `## [` heading.
