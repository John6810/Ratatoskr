---
description: Generate a Conventional Commit message for currently staged changes
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git branch:*)
---

## Current branch
!`git branch --show-current`

## Staged files
!`git status --short`

## Stat summary
!`git diff --cached --stat`

## Diff (truncated to 300 lines)
!`git diff --cached | head -300`

## Recent commits (for style reference)
!`git log --oneline -10`

## Your task

Write a single Conventional Commit message for the staged changes above.

### Rules

- **Format**: `type(scope): subject` — lowercase, no period, imperative mood, ≤ 72 chars
- **Allowed types**: `feat`, `fix`, `docs`, `chore`, `refactor`, `style`, `test`, `build`, `ci`, `perf`
- **Common scopes for ratatoskr**: `docker`, `compose`, `helm`, `kustomize`, `argocd`, `terraform`, `docs`, `readme`, `ci`, `deps`, `claude` (for `.claude/` changes)
- **Body** (optional, blank line after subject): explain *why*, not *what*. Wrap at 72 chars.
- **Footer** (optional): `BREAKING CHANGE: <description>` for breaking changes; `Refs: #123` for issue references.

### Atomicity check first

Before writing the message, look at the diff. If the staged changes touch multiple unrelated concerns (e.g. a Dockerfile fix AND a new Helm template), **flag it and suggest splitting into multiple commits** rather than producing a vague catch-all message. Atomic commits are a project rule.

### Output format

Print exactly this:

```
<type>(<scope>): <subject>

<body if needed>

<footer if needed>
```

Then below it, on a separate line, print the exact command to run:

```bash
git commit -m "<type>(<scope>): <subject>" -m "<body>" -m "<footer>"
```

Or for a simple one-line commit:

```bash
git commit -m "<type>(<scope>): <subject>"
```

**Do not execute the commit.** The user reviews the message and runs the command themselves.

If the staged set is empty, say so and stop.
