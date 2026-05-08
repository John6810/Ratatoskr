# `kustomize/overlays/prod-rwo/secrets/`

Drop your sealed-secret manifests here, then uncomment the corresponding `resources:` lines in `../kustomization.yaml`.

ratatoskr ships **no secret manifests** at this level — applying `CHANGEME` literals would create live Secrets with placeholder credentials and is a guaranteed compromise on first pod boot. See [ADR-0004](../../../../docs/adr/0004-secret-management.md).

## Workflow

1. **Copy the templates** from `kustomize/base/secrets-templates/` into your fork at this directory:
   ```bash
   cp kustomize/base/secrets-templates/{unit3d,mariadb,redis,meilisearch}-secrets.yaml \
      kustomize/overlays/prod-rwo/secrets/
   # only if S3 routing is enabled (ADR-0002):
   cp kustomize/base/secrets-templates/unit3d-storage-secrets.yaml \
      kustomize/overlays/prod-rwo/secrets/
   ```

2. **Replace every `CHANGEME`** with a real value:
   - `APP_KEY` (one-shot, never rotated): `docker run --rm ghcr.io/john6810/unit3d:v9.2.0 php /app/artisan key:generate --show`
   - Passwords: `openssl rand -hex 32`
   - S3 credentials (if enabled): from your bucket provider's console.

3. **Seal each file** against your cluster's sealed-secrets controller pubkey:
   ```bash
   for f in unit3d-secrets mariadb-secrets redis-secrets meilisearch-secrets; do
     kubeseal --format yaml \
       --controller-namespace sealed-secrets \
       < $f.yaml > $f-sealed.yaml
     rm $f.yaml   # NEVER commit the cleartext template after filling it
   done
   ```

4. **Uncomment** the matching `resources:` lines in `../kustomization.yaml`. Leave the `unit3d-storage-secrets-sealed.yaml` line commented unless you have opted into S3 routing per ADR-0002.

5. **`git add` only the `*-sealed.yaml` files**, plus the `kustomization.yaml` change. The cleartext `*-secrets.yaml` templates from step 1 should never reach a commit — `git stash drop` does not erase them from the reflog. If you committed by accident, rotate the affected value.

## external-secrets-operator (ESO) alternative

Skip kubeseal. Instead:

1. Push every value to your KMS backend (AWS Secrets Manager, Vault, GCP Secret Manager, Azure Key Vault).
2. Drop `ExternalSecret` resources in this directory (one per Secret name) referencing your `SecretStore` or `ClusterSecretStore`.
3. Uncomment the matching `resources:` lines in `../kustomization.yaml` (same names — `ExternalSecret` produces a Secret with the named target).

ESO upstream docs cover per-provider setup: <https://external-secrets.io/>.

## See also

- [ADR-0004](../../../../docs/adr/0004-secret-management.md) — sealed-secrets default, ESO alternative, APP_KEY rotation policy.
- [`kustomize/base/secrets-templates/`](../../../base/secrets-templates/) — the canonical templates this directory copies from.
