# ADR-0004: Secret management

- **Status**: Proposed
- **Date**: 2026-05-06
- **Deciders**: <leave blank for now>
- **Tags**: `secrets`, `security`, `kubernetes`

## Context

Secret management spans the full multi-level positioning:

- **Level 1 (Compose)** — `.env` file on the host, gitignored. `compose/.env.example` ships `CHANGEME` placeholders. No cluster-side secret machinery exists; the operator's host filesystem is the trust boundary.
- **Level 2 (K3s)** — first cluster context. Most self-hosted K3s deployments install sealed-secrets out of the box; secrets are sealed against the cluster pubkey and committed to git, then decrypted in-cluster by the controller. GitOps-native, no external dependency.
- **Level 3 (multi-node K8s prod)** — operator profile splits. Self-hosted clusters run sealed-secrets. Cloud/enterprise clusters typically already have AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager, or Azure Key Vault — they want secrets sourced from there via external-secrets-operator (ESO) rather than re-implementing storage at the cluster layer.
- **Level 4 (Terraform IaC)** — same as Level 3 plus Terraform-managed bootstrap (sealed-secrets controller install, ESO `SecretStore` provisioning, IAM/Vault binding).

`CLAUDE.md` and `.claude/rules/k8s.md` already commit ratatoskr to two non-negotiables: **sealed-secrets is the default**, and **APP_KEY is generated once and never regenerated**. The `security-auditor` agent flags raw base64 Secrets in committed manifests as CRITICAL ("base64 is encoding, not encryption"). This ADR fills in the rest of the picture: the ESO alternative path, the per-secret inventory, and the bootstrap and rotation lifecycle.

**Secret inventory at v0.3** (composite from CLAUDE.md, ADR-0002, and the v0.2 backup pipeline):

| Secret | Component | Lifecycle |
|---|---|---|
| `APP_KEY` | `unit3d-secrets` | Generated once at first deploy, **never rotated** |
| `DB_PASSWORD` (unit3d user) | `mariadb-secrets` | Generated once, rotation possible with coordinated app restart |
| `MARIADB_ROOT_PASSWORD` | `mariadb-secrets` | **Permanent** — high-privilege admin credential retained for the lifetime of the deployment (schema repairs, manual `mariadbd` ops, support of last resort). Not deleted post-bootstrap. Consistency with `compose/.env.example`, which keeps the variable indefinitely. Treat with respect: never expose beyond cluster `Secret` + RBAC; never log; never embed in CI. |
| `MARIADB_BACKUP_PASSWORD` | `mariadb-secrets` | Generated once at first deploy alongside DB_PASSWORD; consumed by `ratatoskr-backup` |
| `REDIS_PASSWORD` | `redis-secrets` | **Mandatory in v0.3 prod.** Compose already enforces this at `compose/docker-compose.yml:37-38` via `redis-server --requirepass ${REDIS_PASSWORD:?}` (the `:?` syntax fails fast if unset); the healthcheck at `:44` consumes the same value. v0.3 prod inherits the policy. NetworkPolicy is defense-in-depth, never a replacement for auth. Optional in dev for ergonomic local development. |
| `MEILI_MASTER_KEY` | `meilisearch-secrets` | Generated once |
| `DEFAULT_OWNER_PASSWORD` | `unit3d-secrets` | **First-boot only**; operator rotates via UNIT3D admin UI immediately after login |
| `S3_*` credentials (3 disks) | `unit3d-storage-secrets` | Operator-supplied; rotation via ESO trivial, sealed-secrets requires re-seal |
| `RESTIC_PASSWORD` | `unit3d-backup-secrets` | Generated once at backup-pipeline bootstrap; **losing this loses the backups** |
| `B2_ACCOUNT_ID` / `B2_ACCOUNT_KEY` (or `AWS_*` for S3-compatible backup backends) | `unit3d-backup-secrets` | Operator-supplied |

**The `APP_KEY` rotation footgun.** Laravel's `APP_KEY` encrypts every encrypted column (`encrypted` casts), every signed URL, every encrypted session cookie, every encrypted Redis cache key with `Crypt::encrypt`. Rotating it without an explicit re-encryption migration **corrupts data silently** — old ciphertexts decrypt to garbage, signed URLs return 403, sessions invalidate. UNIT3D ships no built-in key-rotation procedure. <!-- VERIFY: confirm UNIT3D v9.2.0 ships no `php artisan key:rotate` or equivalent; Laravel 12 itself does not ship one out of the box. --> The `k8s-reviewer` agent already flags any workflow that runs `php artisan key:generate` after first-boot as CRITICAL. The first-boot generation must be idempotent (`--no-overwrite-existing` if `key:generate` is invoked, or — preferred — a one-shot Job that runs once and exits).

**Sealed-secrets vs ESO — operational trade-offs:**

| Axis | sealed-secrets | external-secrets-operator |
|---|---|---|
| Source of truth | Sealed YAML in git | External KMS (AWS SM / Vault / GCP / Azure) |
| Encryption | Cluster pubkey, decrypt in-cluster | KMS-side; pulled at sync interval |
| GitOps fit | Native (sealed YAML committed) | Native (`ExternalSecret` resource committed) |
| Cluster portability | **Cluster-bound** (re-seal on migration) | Portable (re-bind `SecretStore`, secrets follow) |
| Audit log | None (controller logs only) | KMS-side audit |
| Rotation | Manual re-seal + commit | KMS rotates, ESO syncs |
| External dependency | None (controller in-cluster) | KMS service + IAM/Vault binding |
| Bootstrap complexity | Low (controller install) | Higher (KMS account + IAM + `SecretStore`) |

Neither is universally better — operators choose based on what they already run.

## Decision

Ship v0.3 with **sealed-secrets as the default** for the prod overlay, **external-secrets-operator (ESO) as a first-class alternative** via a Kustomize component toggle. Both populate the same `Secret` resource shape under the same `<component>-secrets` names; pod manifests reference secrets via `valueFrom.secretKeyRef` regardless of source.

**Secret naming convention** (aligned with `.claude/rules/k8s.md`):

- `unit3d-secrets` — `APP_KEY`, `DEFAULT_OWNER_PASSWORD`, app-level secrets
- `mariadb-secrets` — `MARIADB_ROOT_PASSWORD`, `DB_PASSWORD`, `MARIADB_BACKUP_PASSWORD`
- `redis-secrets` — `REDIS_PASSWORD` (**mandatory in prod**, matching Compose's `--requirepass ${REDIS_PASSWORD:?}` enforcement at `compose/docker-compose.yml:37-38`; optional in dev)
- `meilisearch-secrets` — `MEILI_MASTER_KEY`
- `unit3d-storage-secrets` — S3 credentials for the three Storage-aware disks (`torrent-files`, `subtitle-files`, `attachment-files`) — see ADR-0002
- `unit3d-backup-secrets` — `RESTIC_PASSWORD`, backup-backend credentials (`B2_*` or `AWS_*`) — see v0.2 backup pipeline

Pod manifests reference these via `envFrom.secretRef` (whole Secret as env block) or `env[].valueFrom.secretKeyRef` (single key). Never `value:`.

**Source toggle** (Kustomize component at v0.3, Helm value at v0.5):

- **`overlays/prod` (default): sealed-secrets.** Sealed YAML lives under `kustomize/overlays/prod/sealed-secrets/<component>.yaml`, encrypted against the cluster pubkey via the `kubeseal` CLI. Operators commit the sealed files to their own GitOps repo (a fork or downstream copy of ratatoskr's manifests). The ratatoskr repo ships **template manifests with `CHANGEME` placeholders**, never sealed real secrets — sealing is per-cluster.
- **`overlays/prod` + `components/external-secrets`: ESO.** The component swaps in `ExternalSecret` resources referencing an operator-supplied `SecretStore` (AWS SM, Vault, GCP, Azure). The component's `kustomization.yaml` excludes the sealed-secrets directory. Operator wires the `SecretStore` outside ratatoskr.

**`APP_KEY` provisioning** (generated once, **never rotated**, two paths):

- **DEFAULT — operator-supplied.** The operator generates `APP_KEY` locally with `php artisan key:generate --show` (or any `base64:`-prefixed 32-byte key) and lands it in `unit3d-secrets`:
  - **Sealed-secrets path:** seal the key into `unit3d-secrets` via `kubeseal` and commit the sealed manifest to the operator's GitOps repo.
  - **ESO path:** push the key to the configured KMS backend (AWS Secrets Manager, Vault, GCP Secret Manager, Azure Key Vault); ESO syncs it into `unit3d-secrets` at runtime.
  - **No in-cluster generation Job runs.** The cluster only ever sees a populated `Secret`. This is the prod-grade flow and the canonical sealed-secrets-default GitOps model — operator owns the key, cluster reads it.

- **OPTIONAL — self-bootstrap Job.** For "deploy-and-go" first-time operators who want a working tracker without learning `kubeseal` first, ratatoskr ships an opt-in `unit3d-bootstrap` Job (Kustomize one-shot at v0.3, Helm pre-install hook at v0.5) gated by overlay value `bootstrap.appKey.enabled=true` (or equivalent Helm value at v0.5). The Job:
  - Generates `APP_KEY` in-cluster on a fresh install only, writing to `unit3d-secrets` via the Kubernetes API.
  - **No-ops** if `unit3d-secrets` already contains a non-empty `APP_KEY` — idempotent across redeploys.
  - Runs with a dedicated `ServiceAccount` and the minimum RBAC needed: `patch` on the `unit3d-secrets` Secret only, no other access.
  - **Off by default** in `overlays/prod`. Operators learning Kubernetes flip it on for their first cluster, then graduate to operator-supplied for production.

Both paths converge on the same invariant: **`APP_KEY` is generated exactly once and never regenerated.** Subsequent `unit3d-migrate` Jobs run `php artisan migrate --force --seed` only — never `key:generate`. Rotation is explicitly out of scope; if a future need arises (compromise, audit), the operator follows the manual procedure documented in the operator guide. The `k8s-reviewer` agent flags any workflow that runs `key:generate` after first-boot as CRITICAL.

**`DEFAULT_OWNER_PASSWORD` policy** (first-boot only):

- Used by the seed step of the migrate Job to create the bootstrap admin user.
- Operator rotates via the UNIT3D admin UI on first login; the value in `unit3d-secrets` becomes stale and unused.
- The operator guide instructs deletion of the `DEFAULT_OWNER_PASSWORD` key from `unit3d-secrets` post-bootstrap. The Secret itself remains (other keys still in use). <!-- VERIFY: confirm UNIT3D v9.2.0 reads `DEFAULT_OWNER_PASSWORD` only on seed and not on subsequent boots; if read on every boot, the key cannot be safely deleted. -->

**Compose path (Level 1)** stays `.env`-based — no sealed-secrets at Compose level. `compose/.env.example` retains `CHANGEME` placeholders, `.gitignore` covers `.env` and friends. The `security-auditor` agent's check #5 already enforces this.

## Consequences

### Positive
- **Self-hosted operators get sealed-secrets**, GitOps-native, zero external dependencies. The friction-free default for the multi-level positioning's bread-and-butter operator profile.
- **Cloud/enterprise operators get ESO**, integration with existing KMS infrastructure, central audit and rotation. No "you must run sealed-secrets to use ratatoskr" failure mode.
- **Pod manifests stay topology-agnostic.** Same `valueFrom.secretKeyRef` references regardless of which mechanism populates the Secret. Switching ESO ↔ sealed-secrets does not touch any Deployment/StatefulSet/CronJob spec.
- **APP_KEY rotation footgun documented loudly** and structurally prevented by the bootstrap Job's idempotency guard. The `k8s-reviewer` agent enforces no `key:generate` in per-deploy workflows; this ADR codifies the lifecycle.
- **Secret naming convention is enforced** by `.claude/rules/k8s.md` and the `k8s-reviewer` agent on every PR. Drift between manifests and convention is a review blocker.

### Negative
- **Two secret-population paths to test** (sealed-secrets and ESO). CI must build both overlays; operators following one path may not catch breakage in the other. Mitigated by the `kustomize-validate` skill running both paths.
- **sealed-secrets is cluster-bound.** Operators migrating clusters re-seal every secret against the new cluster pubkey. Documented in the operator guide; ratatoskr does not automate cross-cluster migration.
- **`DEFAULT_OWNER_PASSWORD` lifecycle is awkward.** The Secret key exists post-bootstrap but is unused; operator manually deletes per guide. <!-- VERIFY above. -->
- **ESO bootstrap requires KMS + IAM setup outside ratatoskr.** v0.3 documents the path but does not ship per-provider recipes for AWS Secrets Manager, Vault, GCP Secret Manager, or Azure Key Vault. Operator follows upstream ESO docs for their backend.
- **APP_KEY rotation is genuinely hard.** Any future need (compromise, audit requirement) requires a manual procedure outside ratatoskr's automation: generate new key, re-encrypt every encrypted column via a custom Laravel command, swap `unit3d-secrets`, restart pods. v0.3 ships no rotation tooling. Compromise of `APP_KEY` is a high-impact incident, not a routine rotation event.
- **`RESTIC_PASSWORD` loss is unrecoverable.** Restic encrypts client-side; without the password, backups are ciphertext. The operator guide already covers this (Shamir 3-of-5 escrow in v0.2 docs); this ADR reaffirms it as a key-management invariant.

### Neutral
- Compose path stays `.env`-based — no sealed-secrets pretense at Level 1. Aligned with the multi-level honesty principle (different stack at different levels is acceptable when the levels target different operator profiles; secret machinery is one such case).
- `redis-secrets` is mandatory in prod (covered above) and optional in dev. Dev operators can omit Redis auth for ergonomic local development; prod inherits the Compose enforcement pattern unconditionally.

## Out of scope

- **APP_KEY rotation tooling.** Manual procedure documented in the operator guide; tooling would require deep Laravel integration (re-encrypting every column with `encrypted` cast, re-signing URLs, invalidating sessions). No upstream Laravel primitive exists today. Reopen if upstream lands one. <!-- VERIFY: re-evaluate at every Laravel major bump; check for `key:rotate` or equivalent. -->
- **Per-provider ESO recipes** (AWS Secrets Manager, Vault, GCP Secret Manager, Azure Key Vault, Bitwarden Secret Manager, Doppler, Infisical). ratatoskr documents the toggle and links upstream ESO docs; per-provider `SecretStore` snippets are operator responsibility.
- **Secret rotation cadence enforcement.** Operator policy. ratatoskr does not enforce minimum rotation intervals on `DB_PASSWORD`, `REDIS_PASSWORD`, `MEILI_MASTER_KEY`, etc.
- **Cosign verification of the sealed-secrets controller image / ESO image.** Supply-chain audit territory (`security-auditor` agent), not this ADR. Operators verify upstream signatures themselves at install time.
- **Secret scanning of the ratatoskr repo itself** (gitleaks, trufflehog, GitHub secret scanning). Already covered by CI hooks; this ADR does not duplicate the policy.

## Alternatives considered

- **Raw `Secret` resources committed with base64.** Rejected: explicitly forbidden by `.claude/rules/k8s.md` and flagged as CRITICAL by `security-auditor`. Base64 is encoding, not encryption — the secret is in cleartext for anyone with read access to the repo.
- **SOPS (Mozilla SOPS) with age or PGP keys.** Considered. Encrypts secret YAML in git; operators decrypt with their key. Rejected as default because per-operator key distribution adds friction that sealed-secrets's controller-side decryption avoids. **Reopen at v0.5 (Helm chart) if operator demand emerges**; SOPS plays well with `kustomize` via `ksops` plugin, but Helm-side support typically goes through `helm-secrets` plugin which adds another moving part.
- **HashiCorp Vault Agent Sidecar** (Vault-side rendering, sidecar injects rendered files into pods). Rejected: pod-level injection couples app pods to Vault availability — Vault outage delays pod starts. ESO's `Secret`-resource-shape pattern decouples pod boot from secret backend liveness.
- **Kubernetes encryption-at-rest only (no controller-side encryption).** Half-measure. Solves data-at-rest in etcd but does not address the GitOps committing-base64-to-repo problem. Rejected.
- **Generate `APP_KEY` per pod via initContainer.** Different `APP_KEY` per pod breaks session decryption across pods, signed URLs across pods, encrypted column reads across pods. Rejected categorically.
- **Generate every secret via Helm `randAlphaNum`.** Workable for first-deploy bootstrap, but Helm regenerates on `helm upgrade --reset-values` (operator footgun) and the secrets are emitted into the rendered manifest (potential leak via `helm template` + commit). Rejected; the bootstrap Job pattern is safer.
- **Manage all secrets via plain Kubernetes Secret + RBAC-restricted access.** Rejected: contradicts the GitOps premise (the secret never appears in git, so operators can't reproduce a cluster from manifests alone). This is fine for one-off dev clusters; production wants reproducibility.

## References

- ratatoskr K8s rules — Secrets section: [.claude/rules/k8s.md](../../.claude/rules/k8s.md)
- ratatoskr `CLAUDE.md` — Secrets convention: [.claude/CLAUDE.md](../../.claude/CLAUDE.md)
- `security-auditor` agent — Secrets management checks: [.claude/agents/security-auditor.md](../../.claude/agents/security-auditor.md)
- ADR-0002 — `unit3d-storage-secrets` shape: [docs/adr/0002-storage-strategy-unit3d-storage.md](./0002-storage-strategy-unit3d-storage.md)
- v0.2 backup pipeline — `RESTIC_PASSWORD` and backend credentials: [docs/backup-restore.md](../backup-restore.md)
- sealed-secrets: <https://github.com/bitnami-labs/sealed-secrets>
- external-secrets-operator: <https://external-secrets.io/>
- Laravel 12 encryption (`APP_KEY` semantics): <https://laravel.com/docs/12.x/encryption>
- UNIT3D `.env.example` at v9.2.0 (secret env vars): <https://github.com/HDInnovations/UNIT3D/blob/v9.2.0/.env.example>

### Follow-up commits (out of scope for this ADR)

- `docs(adr): create docs/upstream-prs.md` (referenced from ADR-0002) — list ratatoskr-relevant upstream PRs the project tracks (Storage-aware controller refactor for v0.4; potential `key:rotate` upstream).
- ROADMAP update commit (paired with ADR-0002 storage rewording and ADR-0003 ingress rewording) — optionally add a one-line "secret management: sealed-secrets default, ESO alternative" entry to v0.3 if the ROADMAP currently lacks any secret framing.
