---
applies-to:
  - README.md
  - DISCLAIMER.md
  - CONTRIBUTING.md
  - CHANGELOG.md
  - docs/**/*.md
  - "**/README.md"
---

# Documentation rules

> Active when editing public markdown files (root README, docs/, sub-READMEs). Does not apply to `.claude/**` (those have their own conventions). Complements `00-global.md`.

## When to delegate vs edit directly

- **Spawn the `doc-writer` agent** for substantial work: writing a new doc from scratch, restructuring an existing page, or anything that requires the project style guide enforced.
- **Edit directly** for small fixes: typo, broken link, version number, status badge update, single-line clarification. Spawning an agent for a 5-character fix is overkill.

## Style — non-negotiable

- **English only.** No mixed-language docs. Translation files (if any) live in their own subtree and are out of scope.
- **No filler openings.** Never "Welcome to…", "In this document we will…", "Documentation is important…". Start with content.
- **No corporate vocabulary.** Banned: leverage, solution, enterprise-grade, robust, seamlessly, journey, ecosystem (when "stack" works), best-in-class, empower.
- **No "Last updated: YYYY-MM-DD" footers.** Git is the source of truth for timestamps.
- **Sober emoji** in headers OK (⚠️ ✅ 🚀 📚 🔧 🐛). Never in body prose. Never in code blocks.
- **Code blocks always have a language tag** (` ```bash `, ` ```yaml `, ` ```dockerfile `).
- **Examples must run as-is.** No placeholders mid-snippet without a clearly-marked `<...>` and a defensible default below.

## Cross-doc consistency

- **Read sibling docs before adding a new one.** Match the existing tone, header depth, and structure. The repo has a voice — don't invent another mid-tree.
- **Update related docs in the same commit.** A change to the deployment guide that contradicts the README is worse than no docs.
- **Single source of truth per fact.** Versions live in `CLAUDE.md`/Dockerfile/Chart.yaml — docs reference them, do not duplicate. If you find yourself writing "currently we run UNIT3D v9.2.0" in three places, refactor.

## Links

- **Relative links inside the repo**: `[architecture](./architecture.md)` not `https://github.com/john6810/ratatoskr/blob/main/docs/architecture.md`. Survives forks.
- **Absolute links to upstream**: full HTTPS to UNIT3D, Laravel, FrankenPHP, MeiliSearch, Kubernetes docs.
- **Verify every link before committing.** Dead links are credibility leaks.
- **Anchor links match heading text** — Markdown auto-generates anchors. If you change a heading, search the repo for `#old-anchor` and fix it.

## Copyright & AGPL

- **Never paraphrase UNIT3D upstream documentation closely.** Even reworded paragraphs that mirror the original structure are risky. When you need to describe a UNIT3D feature, write from first principles and link to the upstream doc.
- **Quotes from upstream require attribution and brevity.** A short technical quote with a link is fine; a paragraph copy is not.
- **Examples never assume illegal content.** Use Linux ISOs, public datasets, self-produced media, open archives. The repo is infrastructure-only.
- **Reference `DISCLAIMER.md` from any deployment guide** — at minimum a one-line link near the top.

## Mermaid diagrams

- **Default to `flowchart LR` for component graphs**, `sequenceDiagram` for protocols, `gantt` for roadmaps. Avoid exotic types GitHub doesn't render reliably.
- **Keep node labels short.** A node label is not a sentence.
- **Test rendering** before committing — open the Markdown preview or push to a draft PR.

## Hard rules

- **Never edit `LICENSE` or `DISCLAIMER.md`** without explicit user request and a clear reason. Same rule as `00-global.md`, restated because docs PRs touch sensitive files.
- **Never claim a feature works that you haven't verified.** Outdated guides are worse than missing guides — they generate bug reports.
- **Never invent commands, env vars, or config keys.** Read the actual code, lockfile, or config before describing it.
- **CHANGELOG.md is append-at-top.** Newest entry first, immediately under the `# Changelog` header.
