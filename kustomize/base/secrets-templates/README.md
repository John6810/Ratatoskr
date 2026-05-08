# `kustomize/base/secrets-templates/`

**Templates, not resources.** The five Secret manifests in this directory are reference scaffolding — they ship with `CHANGEME` placeholders for every value and are deliberately **not** included in `kustomize/base/kustomization.yaml`'s `resources` list. Applying them as-is would create Secrets whose `CHANGEME` literal values are in the live cluster: a guaranteed compromise the moment a pod reads the env var.

This directory exists to:

1. Document the **shape and naming** of every Secret ratatoskr's manifests reference (per [ADR-0004](../../../docs/adr/0004-secret-management.md) secret inventory).
2. Give operators a starting point for the **kubeseal** or **external-secrets-operator (ESO)** workflow that turns these placeholders into a real secret backend.

## What's here

| File | Secret name | Key count | Purpose |
|---|---|---|---|
| `unit3d-secrets.yaml` | `unit3d-secrets` | 4 | `APP_KEY` (one-shot, never rotated), `DEFAULT_OWNER_*` (first-boot admin) |
| `mariadb-secrets.yaml` | `mariadb-secrets` | 3 | Root, application user, and backup user passwords |
| `redis-secrets.yaml` | `redis-secrets` | 1 | `REDIS_PASSWORD` (mandatory in prod per ADR-0004) |
| `meilisearch-secrets.yaml` | `meilisearch-secrets` | 1 | `MEILI_MASTER_KEY` (16+ bytes) |
| `unit3d-storage-secrets.yaml` | `unit3d-storage-secrets` | 18 | S3 credentials for the three Storage-aware disks per ADR-0002 |

All five files use `stringData` (not `data`) so the `CHANGEME` placeholders are human-readable and editable. `kubeseal` and ESO both handle the base64 encoding for you.

## sealed-secrets workflow (the default per ADR-0004)

Operators using the sealed-secrets controller in their cluster:

1. **Fork ratatoskr or maintain a sibling GitOps repo.** Templates ship here; sealed values do not — your cluster's sealed-secrets pubkey is per-cluster, the seal is bound to that key, so the sealed file belongs in your fork.

2. **Copy the five template files** from `kustomize/base/secrets-templates/` into your fork (typically under `kustomize/overlays/<env>/secrets/` or a sibling repo's `clusters/<name>/secrets/`).

3. **Replace every `CHANGEME`** with a real value:
   - `APP_KEY` — generate once, never rotate (per ADR-0004): `docker run --rm ghcr.io/john6810/unit3d:v9.2.0 php /app/artisan key:generate --show`
   - Passwords (`MARIADB_*`, `DB_PASSWORD`, `REDIS_PASSWORD`, `MEILI_MASTER_KEY`, `DEFAULT_OWNER_PASSWORD`): `openssl rand -hex 32`
   - `DEFAULT_OWNER_NAME` / `_EMAIL`: human values — the bootstrap admin identity. Operator rotates the password via the UNIT3D admin UI on first login; name and email become the long-term admin record.
   - S3 credentials (`FILESYSTEM_*`): from your bucket provider's IAM console (AWS), R2 dashboard, B2 application key page, or MinIO console.

4. **Seal each file** against your cluster's sealed-secrets controller pubkey:
   ```bash
   kubeseal --format yaml \
     --controller-namespace sealed-secrets \
     < unit3d-secrets.yaml \
     > unit3d-secrets-sealed.yaml
   ```

5. **Commit the sealed file** to your fork. **Delete the plain template** — never check in cleartext secrets, even briefly. `git stash drop` does not erase from the reflog; if you committed by accident, rotate the value.

6. **Reference the SealedSecret** from your overlay's `kustomization.yaml`:
   ```yaml
   resources:
     - ../../base
     - secrets/unit3d-secrets-sealed.yaml
     - secrets/mariadb-secrets-sealed.yaml
     - secrets/redis-secrets-sealed.yaml
     - secrets/meilisearch-secrets-sealed.yaml
     - secrets/unit3d-storage-secrets-sealed.yaml   # only if S3 routing is enabled
   ```

The sealed-secrets controller decrypts the SealedSecret in-cluster and produces the underlying Secret, which the Deployments and StatefulSets reference via `secretKeyRef` / `envFrom`. Workload manifests don't change between sealed-secrets and ESO paths — only the secret-population mechanism differs.

## external-secrets-operator (ESO) workflow

Operators using ESO instead of sealed-secrets (cloud KMS, Vault):

1. **Push every value** to your KMS backend (AWS Secrets Manager, HashiCorp Vault, GCP Secret Manager, Azure Key Vault). Naming convention is operator choice; ratatoskr suggests `unit3d/<secret-name>/<key>` for clarity.

2. **Create a `SecretStore`** (or `ClusterSecretStore`) in your `unit3d` namespace pointing at your KMS backend with the appropriate IAM/auth binding. ESO's upstream docs cover per-provider setup: <https://external-secrets.io/>.

3. **Replace each template** with an `ExternalSecret` resource that references the `SecretStore` and lists the keys to pull. The resulting Kubernetes Secret has the same name as the template (`unit3d-secrets`, `mariadb-secrets`, etc.) so the workload manifests reference it unchanged.

4. **Reference the `ExternalSecret` files** from your overlay's `kustomization.yaml`. Skip the sealed-secrets path entirely.

## Why these are not deployable

If `secrets-templates/` were in `kustomize/base/kustomization.yaml`, every overlay would inherit five Secrets with `CHANGEME` values. Operators would discover the compromise on first login (the bootstrap admin password literal is `CHANGEME`), and any window between deploy and rotation is a hole.

The intentional exclusion forces operators through the kubeseal or ESO workflow before the cluster sees any Secret. The cost: copy-paste from this directory into the operator's fork. The benefit: no path that produces a working cluster with placeholder credentials.

## See also

- [ADR-0004](../../../docs/adr/0004-secret-management.md) — full design rationale: sealed-secrets default, ESO alternative, APP_KEY rotation policy, secret naming convention.
- [`docs/backup-restore.md`](../../../docs/backup-restore.md) — `RESTIC_PASSWORD` and backup backend credentials live in a separate `unit3d-backup-secrets` Secret managed by the v0.2 backup pipeline; that lifecycle is covered in the operator guide, not in this v0.3 base scaffolding.
