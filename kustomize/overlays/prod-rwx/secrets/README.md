# `kustomize/overlays/prod-rwx/secrets/`

Drop your sealed-secret manifests here, then uncomment the corresponding `resources:` lines in `../kustomization.yaml`.

ratatoskr ships **no secret manifests** at this level — applying `CHANGEME` literals would create live Secrets with placeholder credentials and is a guaranteed compromise on first pod boot. See [ADR-0004](../../../../docs/adr/0004-secret-management.md).

## `unit3d-storage-secrets` — MANDATORY at prod-rwx

⚠️ **This sealed-secret is required at prod-rwx.** Unlike prod-rwo (where it was optional), the prod-rwx overlay's `values.env` activates S3 routing by default for the 3 Storage-aware disks:

```env
FILESYSTEM_TORRENT_FILES=s3
FILESYSTEM_SUBTITLE_FILES=s3
FILESYSTEM_ATTACHMENT_FILES=s3
```

Without `unit3d-storage-secrets` providing AWS-shaped credentials, Laravel boots fine but the first request that writes to one of the 3 disks (a torrent upload, a subtitle upload, an attachment upload) fails with `S3 driver requires AWS_ACCESS_KEY_ID` (or equivalent error from the `league/flysystem-aws-s3-v3` adapter). The error surfaces in user-facing flows, not at deploy time.

**Required keys** (per disk × 3 disks = 18 total):

- `FILESYSTEM_TORRENT_FILES_KEY`, `_SECRET`, `_REGION`, `_BUCKET`, `_ENDPOINT`, `_USE_PATH_STYLE_ENDPOINT`
- `FILESYSTEM_SUBTITLE_FILES_KEY`, `_SECRET`, `_REGION`, `_BUCKET`, `_ENDPOINT`, `_USE_PATH_STYLE_ENDPOINT`
- `FILESYSTEM_ATTACHMENT_FILES_KEY`, `_SECRET`, `_REGION`, `_BUCKET`, `_ENDPOINT`, `_USE_PATH_STYLE_ENDPOINT`

See [`base/secrets-templates/unit3d-storage-secrets.yaml`](../../../base/secrets-templates/unit3d-storage-secrets.yaml) for the exact key list and naming.

To use the same S3 backend for all 3 disks (typical), set the same `KEY` / `SECRET` / `REGION` / `BUCKET` / `ENDPOINT` / `USE_PATH_STYLE_ENDPOINT` across all 3 groups. The verbose per-disk naming exists to support different backends per disk if needed (e.g. `torrent-files` on Backblaze B2, `subtitle-files` and `attachment-files` on Cloudflare R2).

**Disabling S3 routing instead.** Operators who don't want S3 at prod-rwx (rare — defeats the prod-rwx HA premise; multi-replica `unit3d-app` writing to a shared RWX PVC has higher latency and lower durability than S3) can:

1. Edit `values.env` and set the 3 toggles to `local`:
   ```env
   FILESYSTEM_TORRENT_FILES=local
   FILESYSTEM_SUBTITLE_FILES=local
   FILESYSTEM_ATTACHMENT_FILES=local
   ```
2. Skip generating `unit3d-storage-secrets-sealed.yaml`.
3. Leave the corresponding `resources:` line in `kustomization.yaml` commented out.

All 17 disks then share the `unit3d-storage` PVC (RWX, 50Gi). HA is preserved (RWX = multi-attach), but `.torrent` files (potentially gigabytes each) live alongside avatars and banners on the same PVC. Storage cost and durability profile both worse than S3.

## sealed-secrets workflow

Same kubeseal recipe as [`overlays/prod-rwo/secrets/README.md`](../../prod-rwo/secrets/README.md), repeated here for self-containment:

1. **Install kubeseal** locally (matching your cluster's sealed-secrets controller version):
   ```bash
   # Linux/macOS
   curl -sLo kubeseal.tar.gz https://github.com/bitnami-labs/sealed-secrets/releases/latest/download/kubeseal-linux-amd64.tar.gz
   tar xf kubeseal.tar.gz kubeseal && sudo install -m 755 kubeseal /usr/local/bin/
   ```

2. **Copy templates** from `base/secrets-templates/` into a working directory and fill the `CHANGEME` placeholders:
   ```bash
   mkdir -p /tmp/ratatoskr-secrets
   cp base/secrets-templates/{unit3d,mariadb,redis,meilisearch,unit3d-storage}-secrets.yaml /tmp/ratatoskr-secrets/
   # Edit each file: replace CHANGEME with real values.
   ```

3. **Seal each file** against the cluster's sealed-secrets controller pubkey:
   ```bash
   for f in unit3d mariadb redis meilisearch unit3d-storage; do
     kubeseal --format yaml \
       < /tmp/ratatoskr-secrets/$f-secrets.yaml \
       > kustomize/overlays/prod-rwx/secrets/$f-secrets-sealed.yaml
   done
   ```

4. **Securely delete the cleartext templates:**
   ```bash
   shred -u /tmp/ratatoskr-secrets/*.yaml  # or rm + secure-erase equivalent on macOS
   ```

5. **Uncomment the `- secrets/...-sealed.yaml` lines** in `kustomization.yaml` `resources:` block.

6. **Verify** before committing to your fork:
   ```bash
   # Build the overlay; sealed-secrets controller will decrypt at apply time.
   kubectl kustomize kustomize/overlays/prod-rwx/ | head -20
   # Confirm SealedSecret manifests are present (their plaintext is opaque, that's expected).
   ```

7. **Commit** the sealed-secrets manifests to your operator fork. The sealed payloads are safe to store in git — only the cluster's sealed-secrets controller can decrypt them.

## external-secrets-operator (ESO) alternative

Operators using ESO instead of sealed-secrets:

1. Provision your KMS / Vault / cloud secret store with the equivalent key/value pairs (see `base/secrets-templates/` for the schema).

2. Replace each sealed-secret file with an `ExternalSecret` manifest pointing at your `SecretStore` or `ClusterSecretStore`:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: unit3d-storage-secrets
   spec:
     refreshInterval: 1h
     secretStoreRef:
       name: my-vault-store
       kind: ClusterSecretStore
     target:
       name: unit3d-storage-secrets
       creationPolicy: Owner
     data:
       - secretKey: FILESYSTEM_TORRENT_FILES_KEY
         remoteRef:
           key: prod/ratatoskr/torrent-files
           property: access_key
       # ... 17 more entries
   ```

3. Drop the `ExternalSecret` files in `secrets/` and uncomment the corresponding `resources:` lines.

ESO upstream docs: <https://external-secrets.io/>

## File structure expectations

After completing the workflow above:

```
kustomize/overlays/prod-rwx/secrets/
├── .gitkeep                                  (this directory's tracking placeholder)
├── README.md                                 (this file)
├── unit3d-secrets-sealed.yaml                (operator-generated)
├── mariadb-secrets-sealed.yaml               (operator-generated)
├── redis-secrets-sealed.yaml                 (operator-generated)
├── meilisearch-secrets-sealed.yaml           (operator-generated)
└── unit3d-storage-secrets-sealed.yaml        (operator-generated; MANDATORY at prod-rwx)
```

ratatoskr upstream tracks only `.gitkeep` and `README.md` in this directory. Operator's fork tracks the 5 sealed-secret files (or `ExternalSecret` files, if ESO).

## See also

- [ADR-0004](../../../../docs/adr/0004-secret-management.md) — full sealed-secrets design rationale.
- [`base/secrets-templates/`](../../../base/secrets-templates/) — canonical templates with the exact key schema for each Secret.
- [`overlays/prod-rwo/secrets/README.md`](../../prod-rwo/secrets/README.md) — RWO baseline (where `unit3d-storage-secrets` is optional).
