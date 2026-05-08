# Security hardening

This document covers production hardening steps beyond the v0.3 Kubernetes base. It addresses
infrastructure-layer concerns: network isolation, secret posture, container surface, database
access, and TLS. It does not cover UNIT3D application-level controls (2FA enforcement, invite
gating, ratio policy, ban rules) — those are operator policy configured inside the UNIT3D admin
panel.

For component layout and traffic flow, see [architecture.md](./architecture.md). For the rationale
behind ingress routing and `/announce` constraints, see
[ADR-0003](./adr/0003-ingress-controller-assumption.md). For secret tooling trade-offs, see
[ADR-0004](./adr/0004-secret-management.md).

> ⚠️ Read [DISCLAIMER.md](../DISCLAIMER.md) before deploying. Operators bear full legal
> responsibility for their instance.

## Threat model

ratatoskr is internet-exposed by design. A BitTorrent tracker cannot function behind auth-only
access. The relevant attack surface:

- **Public ingress**: unauthenticated HTTP/S endpoints (`/announce`, `/login`, `/register`,
  `/torrents`) are reachable from the open internet. Rate limiting and IP tracking depend on
  correct client IP propagation.
- **`/announce` abuse**: the announce path receives high-frequency GET requests from every
  connected client. Middleware that rewrites or compresses the bencoded response breaks clients
  silently. See [ADR-0003](./adr/0003-ingress-controller-assumption.md) for the full constraint.
- **Lateral movement post-compromise**: if the application pod is compromised, NetworkPolicy
  enforcement limits what a pivot can reach (MariaDB port, Redis port, MeiliSearch port, 443
  egress — nothing else by default).
- **Secret extraction**: `APP_KEY`, `DB_PASSWORD`, `REDIS_PASSWORD`, and `MEILI_MASTER_KEY` are
  the highest-value secrets. Exposure of `APP_KEY` allows decryption of every encrypted column
  and every signed URL in the database.
- **Supply chain**: the application image is signed with Cosign (shipped at v0.2.0). Operators
  should verify signatures before deploying updated images.
- **Database credential exposure**: the MariaDB `unit3d` user carries limited grants, but
  misconfigured access (too-broad grants, exposed port, missing NetworkPolicy) turns a
  credential leak into a full schema read/write.

Not in scope here: application-layer attacks against UNIT3D's Laravel code (upstream concern),
DDoS at the network edge (CDN / Cloudflare concern, handled before the cluster ingress).

## Network: trusted proxies

`TRUSTED_PROXIES` in the `unit3d-config` ConfigMap tells Laravel which source IPs are trusted to
forward `X-Forwarded-For` headers. Without it, every request appears to originate from the
ingress pod IP — peer tracking, ratio enforcement, ban rules, and rate limits all key off the
wrong address.

Three operator profiles:

**Single Traefik in-cluster (default).** Use the pod CIDR of your cluster. Narrowing to the
actual pod CIDR is always better than leaving it at RFC1918-wide.

```yaml
# kustomize/overlays/prod-rwo/patches/unit3d-config.yaml (or prod-rwx equivalent)
apiVersion: v1
kind: ConfigMap
metadata:
  name: unit3d-config
data:
  TRUSTED_PROXIES: "10.42.0.0/16"  # Replace with your actual pod CIDR
```

**Behind an external CDN (Cloudflare, BunnyCDN).** Set `TRUSTED_PROXIES` to the cluster ingress
CIDR only. Do not list CDN edge IPs in `TRUSTED_PROXIES` — Traefik's `X-Forwarded-For` handling
already strips CDN hops before the header reaches Laravel. Verify your CDN passes a real-IP
header (Cloudflare sends `CF-Connecting-IP`) and configure Traefik's `realIP` middleware or
Cloudflare's trusted-IP passthrough at the ingress layer.

**Direct exposure (no intermediate proxy).** Set `TRUSTED_PROXIES` to the empty string or omit
it — Laravel will read the socket's remote IP directly. This is uncommon; nearly all K8s
deployments have at least one layer of proxy.

`TRUSTED_PROXIES=*` is never acceptable in production. It allows any caller to spoof
`X-Forwarded-For` arbitrarily, making IP-based bans, rate limits, and peer tracking unreliable.

## Network: NetworkPolicy egress tightening

The v0.3 base ships eight NetworkPolicies under `kustomize/base/networkpolicies/` (see the
[README](../kustomize/base/networkpolicies/README.md) for the full table). The default posture is
default-deny with named allows for DNS, intra-namespace traffic, and TCP 443 egress to
non-private IPs.

The 443-egress policy (`20-unit3d-egress-https.yaml`) is wide: it permits all outbound 443
traffic from all UNIT3D workloads. Operators on **Cilium** can tighten this to specific FQDNs.

```yaml
# Cilium-only, operator-extension — NOT shipped in base/
# Restricts unit3d-app S3 egress to specific endpoints only.
# Adapt FQDNs to your actual S3 provider.
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: unit3d-egress-s3-fqdn
  namespace: unit3d
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: unit3d-app
  egress:
    - toFQDNs:
        - matchPattern: "s3.eu-west-1.amazonaws.com"
        - matchPattern: "*.r2.cloudflarestorage.com"
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

Two additional tightening opportunities:

**Scheduler egress.** `unit3d-scheduler` dispatches jobs to Redis and does not need 443 egress
unless TMDB/IMDB enrichment jobs run inside the scheduler pod. If enrichment is handled by queue
workers, patch the scheduler's egress to drop the 443 allow in your overlay.

**SMTP egress.** The base 443 policy covers transactional email APIs (Mailgun, SES HTTPS,
SendGrid). Operators using SMTP+STARTTLS (TCP 587) or implicit-TLS SMTP (TCP 465) must add an
explicit egress rule to the `unit3d-app` and `unit3d-queue` pods. Add a targeted patch in your
overlay:

```yaml
# Illustrative — adapt to your mail gateway IP or FQDN
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: unit3d-egress-smtp
  namespace: unit3d
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: app
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 587
          protocol: TCP
      to:
        - ipBlock:
            cidr: <mail-gateway-ip>/32
```

## Secrets: sealed-secrets vs External Secrets Operator

Per [ADR-0004](./adr/0004-secret-management.md), ratatoskr is secret-tooling-agnostic. Both
paths produce the same `Secret` resource shape under the same `<component>-secrets` names.

**sealed-secrets** encrypts the manifest against the cluster's public key. The sealed YAML lives
in git; the in-cluster controller decrypts it. Simple, no external dependencies, GitOps-native.

Downsides: the seal is cluster-bound (migration to a new cluster requires re-sealing every
secret), rotation means re-sealing and committing, and there is no built-in audit log beyond
controller logs.

```bash
# Seal a new secret for the unit3d namespace
kubectl create secret generic unit3d-secrets \
  --from-literal=APP_KEY="base64:<your-32-byte-key>" \
  --from-literal=DEFAULT_OWNER_PASSWORD="<changeme>" \
  --dry-run=client -o yaml \
  | kubeseal \
      --controller-namespace sealed-secrets \
      --format yaml \
  > kustomize/overlays/prod-rwo/sealed-secrets/unit3d-secrets.yaml
```

**External Secrets Operator (ESO)** pulls values from an external KMS (AWS Secrets Manager,
HashiCorp Vault, Azure Key Vault, GCP Secret Manager) at a configurable sync interval. Rotation
is handled by the KMS; ESO syncs the updated value into the `Secret` without a re-deploy. Audit
trails live in the KMS.

Downsides: requires a running KMS and IAM binding outside the cluster, more moving parts on the
initial bootstrap path.

```yaml
# ClusterSecretStore (operator-supplied, references your KMS backend)
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: ratatoskr-vault
spec:
  provider:
    vault:
      server: "https://vault.example.com"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "ratatoskr"
---
# ExternalSecret that produces the unit3d-secrets Secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: unit3d-secrets
  namespace: unit3d
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ratatoskr-vault
    kind: ClusterSecretStore
  target:
    name: unit3d-secrets
    creationPolicy: Owner
  data:
    - secretKey: APP_KEY
      remoteRef:
        key: ratatoskr/unit3d
        property: APP_KEY
    - secretKey: DEFAULT_OWNER_PASSWORD
      remoteRef:
        key: ratatoskr/unit3d
        property: DEFAULT_OWNER_PASSWORD
```

Both paths converge on the same invariant: `APP_KEY` is generated exactly once and never
regenerated. Rotating `APP_KEY` without a coordinated re-encryption migration corrupts every
encrypted column, invalidates all signed URLs, and terminates all active sessions. See
[ADR-0004](./adr/0004-secret-management.md) for the full footgun documentation.

## Application hardening: rate limiting and abuse mitigation

`kustomize/components/ingress-traefik/middlewares.yaml` ships two Traefik Middlewares applied
to Route 2 (the catch-all, non-`/announce` route) of the IngressRoute.

**`unit3d-rate-limit`** — values as shipped at v0.3:

- `average: 30` requests per second per source IP
- `period: 1s`
- `burst: 60`
- `sourceCriterion.ipStrategy.depth: 1` (reads the rightmost forwarded IP from the
  `X-Forwarded-For` chain)

These thresholds are intentionally permissive for a first deployment. After observing baseline
traffic patterns (typical ratios of browse-to-download, peak announce frequency, API clients),
tighten them in an overlay patch:

```yaml
# kustomize/overlays/prod-rwx/patches/rate-limit.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: unit3d-rate-limit
  namespace: unit3d
spec:
  rateLimit:
    average: 10
    period: 1s
    burst: 20
    sourceCriterion:
      ipStrategy:
        depth: 1
```

**`unit3d-security-headers`** — values as shipped at v0.3:

- `contentTypeNosniff: true` — sends `X-Content-Type-Options: nosniff`
- `browserXssFilter: true` — sends `X-XSS-Protection: 1; mode=block`
- `frameDeny: true` — sends `X-Frame-Options: DENY`
- `referrerPolicy: strict-origin-when-cross-origin`

HSTS (`stsSeconds`) is present in the file but commented out. See the [TLS posture](#tls-posture)
section for when and how to enable it.

**`/announce` is excluded from both middlewares.** Route 1 in the IngressRoute has no
`middlewares:` field at all — structurally, not by convention. Operators adding a global
middleware patch must verify that the announce route retains its empty middleware list. See
[ADR-0003](./adr/0003-ingress-controller-assumption.md) for why rate limiting the announce path
breaks legitimate BitTorrent clients.

**Fail2ban / IP blocking.** ratatoskr does not ship a ban agent. Options:

- **CrowdSec** — Traefik plugin available, community-sourced threat intelligence, reasonable
  operational overhead. The recommended path for operators who want automated banning.
- **Cloudflare WAF rules** — applicable if the deployment sits behind Cloudflare with a paid
  plan. Effective, but introduces a CDN dependency.
- **CrowdSec bouncer at the Traefik ingress** — the Traefik CrowdSec bouncer middleware blocks
  IPs on the CrowdSec blocklist before the request reaches the IngressRoute. Operators add it as
  an additional Middleware on Route 2 only.

## Container hardening

The v0.3 base `deployment.yaml` sets the following on the `unit3d-app` container:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

And at the pod level:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 33    # www-data in the FrankenPHP Debian-based image
  runAsGroup: 33
  fsGroup: 33
```

`readOnlyRootFilesystem: true` is already active in the base. UNIT3D writes to
`/app/storage`, `/app/bootstrap/cache`, `/data/caddy`, `/config/caddy`, and `/tmp` at runtime.
The base deployment mounts `emptyDir` volumes at each of these paths so that the root filesystem
can remain read-only.

**seccomp** is not set in the base manifest. Operators on Kubernetes 1.25+ should enable
`RuntimeDefault`:

```yaml
# Strategic merge patch — add to your overlay
# kustomize/overlays/prod-rwo/patches/unit3d-app-seccomp.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unit3d-app
spec:
  template:
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
```

Apply it via your overlay's `kustomization.yaml`:

```yaml
patches:
  - path: patches/unit3d-app-seccomp.yaml
    target:
      kind: Deployment
      name: unit3d-app
```

The `RuntimeDefault` seccomp profile uses the container runtime's built-in syscall allowlist,
blocking uncommon and dangerous syscalls without requiring a custom profile. It is safe for
FrankenPHP worker mode.

**AppArmor** profiles are distro-dependent and not portable across Kubernetes distributions.
Operators on Ubuntu nodes with AppArmor enabled can add an annotation-based profile, but
ratatoskr does not ship one. Reference the upstream
[Kubernetes AppArmor documentation](https://kubernetes.io/docs/tutorials/security/apparmor/) for
your distro.

## Database hardening

**User grants.** The `unit3d` MariaDB user has grants scoped to the `unit3d` database only — it
cannot read, write, or drop other databases, and cannot create users or modify server
configuration. The `root` user is never used by the application; its password lives in
`mariadb-secrets` and should be treated as a break-glass credential.

**Backup user.** The `backup` user (referenced in [backup-restore.md](./backup-restore.md))
requires exactly four privileges:

```sql
GRANT RELOAD, PROCESS, LOCK TABLES, BACKUP_ADMIN ON *.* TO 'backup'@'%';
```

These are the minimum grants for `mariadb-backup` on MariaDB 11. `BACKUP_ADMIN` is required for
the `BACKUP LOCK` and `BACKUP STAGE` statements (replacing the older `FLUSH TABLES WITH READ
LOCK` path). Grant nothing beyond this list.

**Network isolation.** `11-mariadb-ingress.yaml` allows ingress to port 3306 only from pods
carrying the UNIT3D workload labels and the backup component label. MariaDB is never reachable
from the ingress namespace or from outside the cluster. Operators on managed databases (RDS,
Aiven, PlanetScale) must replicate an equivalent firewall rule at the managed DB's network
access controls — the K8s NetworkPolicy does not protect the managed endpoint.

**Audit logging.** MariaDB's `audit_log` plugin is off by default (non-trivial performance cost
on write-heavy workloads). Operators with compliance requirements can enable it via a `my.cnf`
snippet mounted into the MariaDB StatefulSet:

```yaml
# my.cnf excerpt — mount via ConfigMap into /etc/mysql/conf.d/audit.cnf
[mysqld]
plugin_load_add = server_audit
server_audit_logging = ON
server_audit_events = CONNECT,QUERY_DDL,QUERY_DML_NO_SELECT
server_audit_file_path = /var/log/mysql/audit.log
server_audit_file_rotate_size = 100000000
```

`QUERY_DML_NO_SELECT` logs inserts, updates, and deletes without logging reads — a reasonable
default for audit trail purposes that does not double the I/O on a read-heavy search workload.

## TLS posture

**Default (cert-manager + Let's Encrypt).** The `prod-rwo` and `prod-rwx` overlays use the
`ingress-traefik` Component, which includes a cert-manager `ClusterIssuer` configured for HTTP-01
challenge. This is the out-of-the-box path for single-domain deployments.

**DNS-01 for wildcards.** HTTP-01 does not support wildcard certificates. Operators needing
`*.example.com` (or who hit Let's Encrypt HTTP-01 rate limits) use DNS-01 with a DNS provider
plugin. Cloudflare example:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: <operator-email>
    privateKeySecretRef:
      name: letsencrypt-prod-dns-key
    solvers:
      - dns01:
          cloudflare:
            email: <cloudflare-account-email>
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

The Cloudflare API token needs `Zone:Read` and `DNS:Edit` on the target zone. For other DNS
providers, see the [cert-manager DNS-01 provider documentation](https://cert-manager.io/docs/configuration/acme/dns01/).

**HSTS.** The `unit3d-security-headers` Middleware in `middlewares.yaml` has HSTS commented out:

```yaml
# stsSeconds: 31536000
# stsIncludeSubdomains: true
# stsPreload: true
```

Enable HSTS only when `INGRESS_TLS=letsencrypt` and you are certain the domain will stay on HTTPS
permanently. A recommended max-age is `31536000` (one year). Do not enable it when
`INGRESS_TLS=external` — the upstream LB already sets HSTS, and conflicting values from two
layers can lock users out of the site for the longer of the two windows.

To activate HSTS in your overlay:

```yaml
# kustomize/overlays/prod-rwo/patches/security-headers-hsts.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: unit3d-security-headers
  namespace: unit3d
spec:
  headers:
    stsSeconds: 31536000
    stsIncludeSubdomains: true
    stsPreload: true
```

**Cipher selection.** Traefik's default TLS configuration enforces TLS 1.2 minimum with a modern
cipher suite. For TLS 1.3-only, configure a custom TLS options object in Traefik's static config
or via a `TLSOption` CRD. See the
[Traefik TLS documentation](https://doc.traefik.io/traefik/https/tls/) for operator-specific
configuration.

## Audit and incident response

**Application logs.** UNIT3D emits logs to stdout via Laravel's Monolog integration. In a K8s
deployment, `kubectl logs` surfaces them immediately. For persistence and search, forward pod
logs to a Loki + Grafana stack or your preferred log aggregation backend. A monitoring guide is
planned for a future release.

**Kubernetes audit logs.** The kube-apiserver can emit structured audit events covering every
API call — Secret reads, Deployment mutations, RBAC escalations. Audit log configuration is
cluster-side and outside ratatoskr's scope, but operators on production clusters should enable
at least `Metadata`-level auditing for the `unit3d` namespace. See the
[Kubernetes audit documentation](https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/).

**Incident response.** The rollback path for application updates is documented in
[upgrade-guide.md](./upgrade-guide.md). Database restoration procedures are in
[backup-restore.md](./backup-restore.md). For a `APP_KEY` compromise (the highest-severity
incident), the recovery path requires re-encrypting every encrypted column with a new key — there
is no automated procedure in ratatoskr at v0.3. Treat `APP_KEY` exposure as a full
incident requiring database re-encryption, session invalidation, and a post-incident audit of
affected encrypted fields.

## See also

- [docs/architecture.md](./architecture.md) — component graph and request flow
- [docs/upgrade-guide.md](./upgrade-guide.md) — rollback procedures
- [docs/backup-restore.md](./backup-restore.md) — backup pipeline and restore procedures
- [docs/adr/0003-ingress-controller-assumption.md](./adr/0003-ingress-controller-assumption.md) — ingress routing and `/announce` no-middleware contract
- [docs/adr/0004-secret-management.md](./adr/0004-secret-management.md) — sealed-secrets / ESO neutrality and `APP_KEY` lifecycle
