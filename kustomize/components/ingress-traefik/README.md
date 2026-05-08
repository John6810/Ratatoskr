# `kustomize/components/ingress-traefik/`

Reusable Kustomize Component composing a Traefik `IngressRoute` + Middlewares + cert-manager `ClusterIssuer` + `Certificate` for the unit3d-app web tier. Designed to be included by the `prod-rwo` and `prod-rwx` overlays (and any operator-defined variant) per [ADR-0003](../../../docs/adr/0003-ingress-controller-assumption.md).

## What this Component ships

| File | Resource | Purpose |
|---|---|---|
| `ingressroute.yaml` | `traefik.io/v1alpha1 IngressRoute` | Two-Route split: `/announce` middleware-free; catch-all with rate-limit + security-headers |
| `middlewares.yaml` | `traefik.io/v1alpha1 Middleware` × 2 | `unit3d-rate-limit` (30 req/s avg, 60 burst, IP-aware), `unit3d-security-headers` (frame-deny, content-type-nosniff, referrer-policy) |
| `clusterissuer.yaml` | `cert-manager.io/v1 ClusterIssuer` | Let's Encrypt production, HTTP-01 challenge via Traefik vanilla Ingress class |
| `certificate.yaml` | `cert-manager.io/v1 Certificate` | Reference to the ClusterIssuer, populates the `unit3d-tls` Secret consumed by IngressRoute |

## /announce two-Route split — the structural enforcement

ADR-0003 + `.claude/rules/k8s.md` `/announce` traffic rules forbid body-rewriting middleware, redirects, and (by default) gzip on the announce path. Traefik Middlewares attach to a Route, not a path within a Route — so to exempt `/announce` from the catch-all middlewares, the IngressRoute splits into two Routes:

```
Route 1  match: Host(...) && PathPrefix(/announce)   priority: 100   middlewares: (none)
Route 2  match: Host(...)                            priority: 10    middlewares: rate-limit, security-headers
```

Higher priority on Route 1 ensures `/announce` matches first. Route 2 catches everything else. The empty middlewares list on Route 1 makes the invariant visually obvious — anyone reviewing this manifest sees the split.

## Operator workflow — three placeholders to patch

The Component ships with three `CHANGEME` placeholders the operator MUST patch in their overlay:

1. **Host header in IngressRoute** (`ingressroute.yaml`, both Route match strings): `Host(\`tracker.your-domain.example\`)`.
2. **dnsNames in Certificate** (`certificate.yaml`): `dnsNames: [tracker.your-domain.example]` — same domain as the Host, in lockstep.
3. **Email in ClusterIssuer** (`clusterissuer.yaml`): `email: ops@your-domain.example` — Let's Encrypt sends expiration warnings here.

Patch via the overlay's `patches:` block. Strategic merge is the primary recipe — Traefik IngressRoute `routes` is a list with no stable merge key, so a strategic merge that replaces the whole `routes:` block (and `tls:`) is more robust than indexed JSON 6902 patches that break the moment the upstream Component reorders or inserts a Route.

```yaml
# overlays/prod-rwo/kustomization.yaml (excerpt)
patches:
  - target:
      kind: IngressRoute
      name: unit3d-app
    patch: |-
      apiVersion: traefik.io/v1alpha1
      kind: IngressRoute
      metadata:
        name: unit3d-app
      spec:
        routes:
          - match: Host(`tracker.your-domain.example`) && PathPrefix(`/announce`)
            kind: Rule
            priority: 100
            services:
              - name: unit3d-app
                port: 80
          - match: Host(`tracker.your-domain.example`)
            kind: Rule
            priority: 10
            services:
              - name: unit3d-app
                port: 80
            middlewares:
              - name: unit3d-rate-limit
              - name: unit3d-security-headers
        tls:
          secretName: unit3d-tls
  - target:
      kind: Certificate
      name: unit3d-tls
    patch: |-
      apiVersion: cert-manager.io/v1
      kind: Certificate
      metadata:
        name: unit3d-tls
      spec:
        dnsNames:
          - tracker.your-domain.example
  - target:
      kind: ClusterIssuer
      name: letsencrypt-prod
    patch: |-
      apiVersion: cert-manager.io/v1
      kind: ClusterIssuer
      metadata:
        name: letsencrypt-prod
      spec:
        acme:
          email: ops@your-domain.example
```

JSON 6902 is acceptable for fine-grained tweaks (e.g. flipping a single `priority` value), but use strategic merge when replacing structural blocks like `routes:` so overlay patches stay valid across upstream Component evolution.

## INGRESS_TLS toggle (per ADR-0003)

The Component ships with `INGRESS_TLS=letsencrypt` semantics: cert-manager + Let's Encrypt + Traefik IngressRoute with `tls.secretName: unit3d-tls`.

For `INGRESS_TLS=external` (TLS terminated at an upstream LB — Cloudflare Tunnel, AWS ALB with ACM, OVH LB), the operator's overlay patches:
- IngressRoute: drop the `tls:` block, switch `entryPoints` from `websecure` to `web`.
- Don't include this Component's `clusterissuer.yaml` and `certificate.yaml` (operator's overlay omits them via `kustomization.yaml`'s resources list, or includes the Component minus those files via a `patches:` block that deletes them).

A future iteration may split `ingress-traefik-letsencrypt` and `ingress-traefik-external` into two Components if the toggle gets unwieldy. v0.3 keeps it as overlay-level patching.

## ClusterIssuer name conflict

`letsencrypt-prod` is the conventional cert-manager ClusterIssuer name; many self-hosted clusters already have one. Operators with an existing `letsencrypt-prod`:
- Remove `clusterissuer.yaml` from their fork (their existing ClusterIssuer is reused).
- Or rename the Component's ClusterIssuer (patch `metadata.name` and update `certificate.yaml`'s `issuerRef.name` in lockstep).

## Operator namespace label

The base/networkpolicies/30-ingress-to-app.yaml policy permits ingress to unit3d-app:80 from any pod in a namespace labeled `network.ratatoskr.io/ingress=true`. Operators must label the Traefik namespace:

```bash
kubectl label namespace traefik network.ratatoskr.io/ingress=true
# or whatever namespace hosts the Traefik controller pods
```

Without this label, NetworkPolicy blocks Traefik → unit3d-app traffic and the IngressRoute returns 503.

## Swapping to ingress-vanilla

Operators on nginx-ingress, AWS ALB, GCE ingress, or any vanilla `Ingress` controller don't use this Component. A sibling Component `kustomize/components/ingress-vanilla/` (TBD at v0.3 scaffolding — lands when the user decides operator demand justifies it) ships a `networking.k8s.io/v1 Ingress` with annotation sets for the common controllers.

The two Components are mutually exclusive at the overlay level: include one, skip the other.

## See also

- [ADR-0003](../../../docs/adr/0003-ingress-controller-assumption.md) — ingress controller positioning, two-paths design, /announce hard rules.
- [.claude/rules/k8s.md](../../../.claude/rules/k8s.md) — `/announce` traffic rules section.
- [`kustomize/base/networkpolicies/30-ingress-to-app.yaml`](../../base/networkpolicies/30-ingress-to-app.yaml) — the NetworkPolicy that gates ingress to unit3d-app:80.
