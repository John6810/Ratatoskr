# `kustomize/base/networkpolicies/`

Default-deny baseline for the `unit3d` namespace, with additive allows for the traffic ratatoskr's workloads actually need. Eight NetworkPolicies in eight files, prefixed by load order (`00-`, `01-`, `10-`, …) for readability — Kubernetes evaluates all NetworkPolicies in parallel, the prefixes are documentation, not semantic.

## Philosophy

**Default-deny + additive allow.** Without `00-default-deny.yaml`, every other policy is decorative — pods are permitted everything except what explicit denies block, which is the inverse of what we want. Per [`.claude/agents/k8s-reviewer.md`](../../../.claude/agents/k8s-reviewer.md) rule #11, missing default-deny in production is CRITICAL.

Every additional policy in this directory then opens up a specific, justified path:

| File | Subject | Allows |
|---|---|---|
| `00-default-deny.yaml` | All pods | (none — establishes the deny baseline) |
| `01-allow-dns.yaml` | All pods | Egress to `kube-system` on UDP/TCP 53 (CoreDNS). Without this, every pod is broken. |
| `10-unit3d-to-infra.yaml` | UNIT3D workloads (`app`, `worker`, `scheduler`, `migration`) | Egress to `mariadb:3306`, `redis:6379`, `meilisearch:7700` |
| `11-mariadb-ingress.yaml` | MariaDB pods | Ingress from UNIT3D workloads + `backup` component |
| `12-redis-ingress.yaml` | Redis pods | Ingress from UNIT3D workloads + `backup` component (forward-compat) |
| `13-meilisearch-ingress.yaml` | MeiliSearch pods | Ingress from UNIT3D workloads + `backup` component (forward-compat) |
| `20-unit3d-egress-https.yaml` | UNIT3D workloads | Egress on TCP 443 to public internet (S3, OAuth, SMTP-over-TLS), excluding RFC1918 + link-local |
| `30-ingress-to-app.yaml` | `unit3d-app` | Ingress on TCP 80 from any pod in a namespace labeled `network.ratatoskr.io/ingress=true` |

## Operator workflow

**Single requirement: label your ingress namespace.** ratatoskr ships no opinion on which ingress controller you run (per [ADR-0003](../../../docs/adr/0003-ingress-controller-assumption.md): Traefik `IngressRoute` or vanilla `Ingress`, your choice). The single requirement: the namespace where your ingress controller pods live must carry the label `network.ratatoskr.io/ingress=true`. Without this, no traffic reaches `unit3d-app`.

```bash
kubectl label namespace traefik-system network.ratatoskr.io/ingress=true
# or, for nginx-ingress in the ingress-nginx namespace:
kubectl label namespace ingress-nginx network.ratatoskr.io/ingress=true
```

**Everything else is wired by labels** matching the recommended labels convention. `unit3d-app`, `unit3d-queue`, `unit3d-scheduler`, and `unit3d-migrate` already carry `app.kubernetes.io/component=app|worker|scheduler|migration`; `mariadb`, `redis`, and `meilisearch` carry `app.kubernetes.io/name=<component>`. The policies select pods via these labels — no per-environment patching required for the common case.

## What's NOT here

- **L7 / FQDN-aware egress restrictions.** `20-unit3d-egress-https.yaml` permits all 443 traffic to non-private IPs. Restricting to specific S3 endpoints, OAuth providers, etc. requires Cilium L7 or Calico's GlobalNetworkPolicy with FQDNs — out of scope at v0.3 base because not all clusters support these CRDs. Operators on Cilium can layer a `CiliumNetworkPolicy` in their overlay.
- **SMTP on 587/465.** The 443-only egress covers transactional email APIs (Mailgun, SES API, SendGrid HTTPS). Operators using SMTP+STARTTLS or implicit-TLS SMTP patch the egress policy in their overlay.
- **Pod-to-pod inside the namespace.** `unit3d-app` does not talk to other `unit3d-app` pods; queue workers do not talk to each other; etc. No app-to-app rules needed at v0.3.
- **Backup pipeline ingress beyond MariaDB.** Redis and MeiliSearch pre-authorize the `backup` component label as forward-compat. The v0.2 backup pipeline currently only touches MariaDB (via mariabackup); future Redis/Meili backup mechanisms (if added) will inherit the existing ingress allow without amending base/.

## Severity guidance for reviewers

The `k8s-reviewer` agent ([.claude/agents/k8s-reviewer.md](../../../.claude/agents/k8s-reviewer.md)) checks four NetworkPolicy invariants on every PR:

| Rule | Concern | Severity |
|---|---|---|
| #11 | Default-deny present in prod overlay | CRITICAL if missing |
| #12 | `podSelector` matches actual workload labels | bug-class — common source of failures |
| #13 | `policyTypes` set explicitly (not implicit default) | discipline — implicit defaults bite |
| #14 | DNS egress allowed | CRITICAL if missing — every pod broken without it |

This base/ directory satisfies all four.

## See also

- [ADR-0003](../../../docs/adr/0003-ingress-controller-assumption.md) — ingress controller positioning, /announce hard rules.
- [.claude/agents/k8s-reviewer.md](../../../.claude/agents/k8s-reviewer.md) — NetworkPolicy review rules.
- [.claude/rules/k8s.md](../../../.claude/rules/k8s.md) — NetworkPolicy section: default-deny in prod, CoreDNS egress required, policyTypes explicit, podSelector precision.
