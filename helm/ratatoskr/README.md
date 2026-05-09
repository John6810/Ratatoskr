# ratatoskr Helm chart

Production deployment stack for [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D),
packaged as a Helm chart. Sibling to the Kustomize tree under
[`../kustomize/`](../../kustomize/) — same underlying stack, two delivery formats.

## Chart metadata

| Field | Value |
|---|---|
| Chart version | `0.5.0-alpha.1` |
| App version (UNIT3D) | `v9.2.0` |
| Kubernetes | `>=1.30.0-0` |
| License | AGPL-3.0 |

## ⚠️ Status — alpha scaffolding

This is the v0.5.0-alpha.1 scaffold. **Templates are not yet implemented.**
`helm install` produces no Kubernetes resources at this revision; the
chart ships only:

- `Chart.yaml` — chart metadata
- `values.yaml` — full schema with sensible defaults mirroring [`kustomize/base/`](../../kustomize/base/)
- `values.schema.json` — required-field enforcement (`appKey`, MariaDB passwords, Redis password, MeiliSearch master key)
- `templates/_helpers.tpl` — per-component fullname helpers
- `templates/NOTES.txt` — install notice pointing to Kustomize

Full templates land in **v0.5.0-beta.1**. The v0.5 cycle delivers Helm
parity with Kustomize plus Gateway API ingress support — see
[`docs/ROADMAP.md`](../../docs/ROADMAP.md) v0.5.0.

## Install (interim)

Deploy via Kustomize until templates ship:

```bash
kubectl apply -k https://github.com/John6810/Ratatoskr/kustomize/overlays/prod-rwo
```

The Helm path will be:

```bash
helm install ratatoskr oci://ghcr.io/john6810/charts/ratatoskr \
  --version 0.5.0-beta.1 \
  --namespace unit3d --create-namespace \
  -f values-prod.yaml
```

(Pinned once v0.5.0-beta.1 ships and the chart is published.)

## Configuration

Every operator-tunable value is documented in [`values.yaml`](./values.yaml)
with inline comments. Required values (schema-enforced — `helm install`
fails with a clear message if missing):

| Path | Purpose |
|---|---|
| `unit3d.appKey` | Laravel encryption key (`base64:...`). Generate once, never rotate without a re-encryption migration. See [ADR-0004](../../docs/adr/0004-secret-management.md). |
| `mariadb.auth.rootPassword` | MariaDB root password |
| `mariadb.auth.password` | MariaDB application user password |
| `redis.auth.password` | Redis AUTH password |
| `meilisearch.masterKey` | MeiliSearch master key (16+ bytes) |

The schema is defined in [`values.schema.json`](./values.schema.json).
Operators on schema-aware tooling (Helm CLI 3.4+, ArgoCD, Flux) get
typed errors at install time.

## Helm chart vs Kustomize

`helm/ratatoskr/` and [`kustomize/`](../../kustomize/) are sibling
deployment paths backed by the same component definitions. Operators
pick whichever fits their team's tooling — there is no functional
difference once templates ship at v0.5.0-beta.1.

The Kustomize tree is the source of truth for default values. When
`values.yaml` and `kustomize/base/<component>/` disagree, Kustomize
wins until proven otherwise — file an issue.

## See also

- [`docs/architecture.md`](../../docs/architecture.md) — component graph and storage strategy
- [`docs/upgrade-guide.md`](../../docs/upgrade-guide.md) — migration paths
- [`docs/security-hardening.md`](../../docs/security-hardening.md) — production hardening
- [`docs/ROADMAP.md`](../../docs/ROADMAP.md) — v0.5.0 scope
