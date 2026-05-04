# Global rules

> Always active. Behavioral guardrails for every interaction in this repo. Complements `CLAUDE.md` (which describes the project) — this file describes how to *act* on it.

## Delegate to skills and agents

Before doing a task manually, check if a dedicated skill or agent exists. Use the right one:

| Task | Use |
|---|---|
| Check if pinned versions are current | `check-upstream-versions` skill |
| Build & smoke-test the image | `docker-build-local` skill |
| Validate Kustomize overlays | `kustomize-validate` skill |
| Lint Helm chart | `helm-lint` skill |
| Prep a release | `prepare-release` skill |
| Sync README versions | `sync-readme-versions` skill |
| Review K8s manifests | spawn `k8s-reviewer` agent |
| Audit secrets, AGPL, supply chain | spawn `security-auditor` agent |
| Debug Laravel/UNIT3D behavior | spawn `laravel-unit3d-expert` agent |
| Write public docs (README, docs/) | spawn `doc-writer` agent |
| Generate a commit message | `/commit` |
| Document a technical decision | `/adr <title>` |

Do not reimplement what a skill already encodes. If a skill is missing for a recurring task, propose creating one rather than ad-hoc commands every time.

## Always

- **Verify versions from upstream** before writing any version literal in any file. Stale pins are the #1 regression in this project.
- **Run the relevant validation skill** before suggesting a commit that touches Docker / Kustomize / Helm / manifests.
- **Atomic commits.** One logical change per commit. If you find yourself writing "and also" in a commit message, split it.
- **Conventional Commits format** for every commit: `type(scope): subject`. Use `/commit` to generate.
- **Read before write.** Before editing a file, read its current state. Before adding a config key, check if it already exists elsewhere.
- **English in public artifacts.** Conversation with the user can be French casual; everything that ends up on GitHub (code, comments, docs, commit messages, error strings, log messages) is English.

## Never

- **Never change the license.** AGPL-3.0 is inherited from upstream UNIT3D — non-negotiable.
- **Never edit `LICENSE` or `DISCLAIMER.md`** without explicit user request and a clear reason. These are pinned files for a legal reason.
- **Never write content that suggests, implies, or facilitates piracy.** Examples in code, docs, commits, and tests assume legitimate content (ISOs, public datasets, self-produced media). The repo is infrastructure-only.
- **Never invent UNIT3D features, env vars, or behaviors.** If unsure, read the upstream source, fetch the relevant `.env.example` line, or say "I don't know — let's check".
- **Never push to remote, force-push, or tag releases without explicit user confirmation.** Settings already gate these in `ask`; respect the spirit, not just the letter.
- **Never bake secrets into committed files.** Even in test fixtures. Use placeholders (`CHANGEME`) or sealed-secrets references.

## When unsure, escalate

- If two sources of truth disagree (e.g. Dockerfile vs Chart.yaml vs README), stop and surface the conflict before picking one. The fix is to align them, not to silently choose.
- If a request would touch the legal framing of the project (license, disclaimer, contributor terms), pause and confirm with the user before proceeding.
- If a question requires UNIT3D internals you can't verify from this repo or upstream sources, route it through the `laravel-unit3d-expert` agent rather than guessing.

## Reporting style in this repo

- **No emoji in commit messages, code, or code comments.** OK in markdown docs (sober ones: ⚠️ ✅ 🚀 📚 🔧).
- **No corporate fluff anywhere.** No "we provide", "leveraging", "enterprise-grade", "best-in-class", "seamlessly", "robust solution".
- **Short over long when both are accurate.** Lists over prose only when items are parallel and discrete.
- **Code blocks always have a language tag.** Examples must run as-is.
