# ADR-0003: Ingress controller assumption

- **Status**: Proposed
- **Date**: 2026-05-06
- **Deciders**: <leave blank for now>
- **Tags**: `ingress`, `kubernetes`, `tls`

## Context

The v0.3 K8s overlay must commit to an ingress story. Three operator profiles cover the multi-level positioning:

- **Compose (level 1)** — no Kubernetes ingress at all. The Compose stack ships `127.0.0.1:8080:80` and assumes a host-level reverse proxy (Caddy, nginx, Traefik standalone) handles TLS. Out of scope for this ADR.
- **K3s (level 2)** — Traefik is bundled by default and exposed as the cluster ingress. `IngressRoute` CRD is available without extra install steps.
- **Multi-node K8s (level 3)** — operator choice. Traefik, nginx-ingress, HAProxy, AWS ALB, GCE ingress, Contour, Cilium L7 — all real-world deployments at this tier. The cluster may or may not have Traefik CRDs available.

The traffic shape is unusual for a Laravel app and constrains the ingress decision:

- **`/announce`** — BitTorrent client → ratatoskr. `GET` with query string, **bencoded** response body. BitTorrent clients do not reliably follow HTTP redirects (rtorrent, older qBittorrent variants), and body-rewriting middleware would corrupt the bencoded payload. The path must return `200` with byte-identical upstream output. <!-- VERIFY: the body-rewriting ban is currently documented inside this ADR only — neither `.claude/rules/k8s.md` nor `.claude/CLAUDE.md` state it verbatim today. Hoisting the rule into `.claude/rules/k8s.md` is tracked as a separate follow-up commit (`docs(claude): hoist /announce middleware ban into rules`); do not touch those files from this ADR session. -->
- **`/torrents/.../download`** — large `.torrent` file delivery via Laravel routes. Standard HTTP, no special routing constraint, but bandwidth-heavy (sized comparably to the `torrent-files` disk).
- **Everything else** — HTML / Laravel responses, no special handling.

**Reverb absence in v9.2.0 simplifies the picture.** No WebSocket upgrade route, no sticky sessions needed. Laravel sessions live in Redis: `compose/.env.example` in this repo sets `SESSION_DRIVER=redis`, matching the bundled Redis service and CLAUDE.md's `BROADCAST_CONNECTION=redis` stack baseline. Every `unit3d-app` pod can serve any user; affinity is decoupled from correctness.

**TLS termination is a separate concern.** Two patterns are common in self-hosted K8s:

- **In-cluster termination** — cert-manager + Let's Encrypt at the ingress controller. HTTP-01 challenge default; DNS-01 for wildcards or rate-limit-aware operators.
- **Upstream LB termination** — TLS terminated at Cloudflare / AWS ALB / OVH LB / Cloudflare Tunnel; cluster ingress runs plain HTTP behind the LB. Common when operators already pay for managed edge.

ROADMAP v0.3 names "Ingress via Traefik IngressRoute + cert-manager (Let's Encrypt)" as the deliverable. The multi-level promise (working at K3s and at multi-node K8s) means this ADR reads the ROADMAP as Traefik-*default*, not Traefik-only. The double-overlay decision below honors the ROADMAP for the K3s/Traefik path and adds first-class support for cluster-agnostic deployments. ROADMAP wording will be updated to reflect the double overlay in a follow-up commit (see Out of scope).

## Decision

Ship v0.3 with **two first-class ingress paths**, plus a TLS-source toggle that overrides both:

1. **`overlays/prod` (default): Traefik `IngressRoute` + cert-manager.**
   - Matches ROADMAP v0.3 wording and K3s default.
   - `IngressRoute` CRD for routing rules + Traefik middleware (rate limit, headers).
   - cert-manager `ClusterIssuer` for Let's Encrypt; HTTP-01 challenge default, DNS-01 documented for wildcard or rate-limit-sensitive cases.
   - `/announce` route flagged with an in-manifest comment forbidding middleware on that route. The route is intentionally listed before any wildcard catch-all so middleware on `*` does not bleed in.

2. **`overlays/prod-vanilla-ingress`: standard `networking.k8s.io/v1 Ingress` + cert-manager.**
   - Operator brings their own controller (nginx-ingress, HAProxy ingress, AWS ALB, GCE ingress, Contour). No Traefik CRD dependency.
   - Same routing shape; differences are annotations and middleware translation.
   - Example annotations shipped for nginx-ingress and AWS ALB. Other controllers translate from those.
   - `/announce` "no middleware" comment translated per controller (`nginx.ingress.kubernetes.io/configuration-snippet` etc.); operators on niche controllers verify themselves.

3. **TLS source toggle (`INGRESS_TLS` overlay value):**
   - `letsencrypt` (default): cert-manager + Let's Encrypt as described above.
   - `external`: cluster ingress runs HTTP-only on port 80 inside the cluster network; an external LB (Cloudflare, ALB, OVH LB, Cloudflare Tunnel) terminates TLS and forwards plaintext over a private link. The overlay sets `kubernetes.io/tls-acme: "false"` and removes the cert-manager annotations.

**Hard rule on `/announce`.** No middleware that touches request or response **body** on the `/announce` path:
- No body substitution / rewrite middleware.
- No redirects (`return 301`, `return 302`, or controller-level scheme redirects). Path rewriting at the URL level is acceptable only if byte-stable.
- **Response compression discouraged.** gzip on `/announce` may break older or non-mainstream BitTorrent clients with brittle decoders. Default off in both overlays. <!-- VERIFY: confirm gzip-off recommendation against current qBittorrent / Deluge / rtorrent / Transmission behavior — last documented community consensus is "don't risk it"; revisit if upstream UNIT3D ships explicit guidance. -->

**No sticky sessions at v0.3.** Reverb absence in v9.2.0 means no WebSocket affinity requirement; Laravel sessions in Redis make any `unit3d-app` pod fungible. When (if) upstream UNIT3D adopts Reverb, this ADR will be revisited and sticky-session annotations added to the Reverb route specifically — not the main route.

**Trusted proxy configuration is mandatory.** Without it, the ingress controller's pod IP is logged as the client IP for every request — including `/announce`. UNIT3D's peer tracking, ratio enforcement, ban hammer, and rate limits all key off the client IP. With wrong client IPs, every peer appears as a single internal address, breaking the tracker's correctness primitives in subtle and noisy ways. Both overlays MUST forward the standard chain (`X-Forwarded-For`, `X-Forwarded-Proto`, `X-Real-IP`) at the ingress controller, and `unit3d-app` MUST configure `TRUSTED_PROXIES` to recognize the ingress controller's pod CIDR. The base manifests pre-set the env var and the controller annotations; operators who substitute a different ingress controller class verify the equivalent forwarded-headers configuration in their replacement. <!-- VERIFY: confirm UNIT3D v9.2.0 reads `TRUSTED_PROXIES` from env directly, or whether `app/Http/Middleware/TrustProxies.php` is class-hardcoded. If hardcoded, the prod overlay needs a config override (same ConfigMap-mount pattern as ADR-0002) to flip the trusted CIDRs to env-driven. -->.

## Consequences

### Positive
- K3s operators get the friction-free default (Traefik already installed, `IngressRoute` is the K3s idiom).
- Multi-node K8s operators on nginx-ingress / ALB / GCE get a first-class supported path, not an afterthought downgrade.
- TLS-at-upstream-LB is supported via a single overlay value, not a manifest fork.
- `/announce` middleware constraint lives in the manifest comment where operators look first, not buried in `docs/`.
- No sticky-session footguns at v0.3 — Reverb absence is leverage, not a missing feature.

### Negative
- **Two overlays to maintain.** Every routing change lands in both. Mitigated by keeping middleware-rich logic in the Traefik overlay only and the vanilla overlay deliberately minimal.
- **Niche controllers translate from the vanilla overlay.** Istio Gateway API, Cilium L7, Kong, Traefik-as-Ingress (not as IngressRoute) — annotation-equivalence gaps possible. Documented as operator responsibility.
- **`/announce` middleware avoidance is operator responsibility** in the vanilla overlay path. ratatoskr documents the rule, ships in-manifest comments, and the `k8s-reviewer` agent flags violations on PRs that touch ingress routing — but cannot prevent operators from adding harmful middleware in their own customizations.
- **DNS-01 cert-manager flow requires per-provider configuration** (Cloudflare, Route53, Gandi, …). Out of scope for ratatoskr to ship every variant; we document Cloudflare as the most common, link upstream cert-manager docs for others.

### Neutral
- Cluster-agnostic overlay ships example annotations for nginx-ingress and AWS ALB. Other controllers reuse the same `Ingress` resource shape with their own annotation dialect.
- Gateway API support is **deferred to v0.5** (Helm chart release), when adoption parity across Traefik / nginx / Contour is more uniform. <!-- VERIFY: re-evaluate Gateway API maturity at v0.5; especially whether Traefik's Gateway API implementation has reached feature parity with `IngressRoute` for the middleware ratatoskr uses. -->

## Out of scope

- **Future Reverb / WebSocket support.** v0.3 is explicitly scoped to UNIT3D v9.2.0, which ships no WebSocket server. If a future UNIT3D release adopts Reverb (or Soketi, or any browser-facing WS), the "no sticky sessions" assumption breaks: the WebSocket route needs sticky-session annotations on a Reverb-only Service, possibly per-controller affinity tweaks. A successor ADR will land in the same release cycle as the upstream WS adoption. ratatoskr will follow upstream rather than fork-ship a Reverb container ahead of upstream.
- **ROADMAP v0.3 ingress wording update.** The ROADMAP currently reads "Ingress via Traefik IngressRoute + cert-manager (Let's Encrypt)"; the double-overlay decision means this should read "default Traefik IngressRoute, alternative cluster-agnostic Ingress, both with cert-manager (Let's Encrypt) by default and an upstream-LB TLS toggle". Will be updated in a follow-up commit alongside the ROADMAP v0.4 storage rewording from ADR-0002.
- **Per-overlay annotations for niche controllers** (Istio Gateway API, Cilium L7, Kong, Contour). The vanilla overlay's annotation set is targeted at nginx-ingress and AWS ALB. Other controllers translate from there; ratatoskr does not ship a curated overlay per minor controller dialect.
- **DNS-01 challenge configuration per provider.** ratatoskr documents Cloudflare as the most common DNS-01 path and links upstream cert-manager docs. Per-provider Helm values or sealed `IssuerRef` snippets are not shipped.

## Alternatives considered

- **Traefik `IngressRoute` only.** Rejected: locks ratatoskr to a Traefik CRD dependency, breaks the multi-level promise for operators on nginx-ingress / HAProxy / cloud LBs. K3s operators are well-served, but level 3 operators are penalized.
- **Vanilla `Ingress` only.** Rejected: K3s ships Traefik as the default ingress controller, and `IngressRoute` is the K3s-idiomatic shape. Downgrading to vanilla loses Traefik-native middleware (rate limit, headers, basic auth) that operators want without adding annotations or sidecars.
- **Gateway API (`gateway.networking.k8s.io`).** Considered. Modern, controller-agnostic, the eventual destination. Adoption in self-hosted clusters is still uneven at the v0.3 release date — Traefik's Gateway API support is GA but lags `IngressRoute` features used in middleware chaining. Reopen at v0.5.
- **No ingress shipped — operators bring their own.** Rejected: makes v0.3 a half-deployment. The ratatoskr promise is "`kubectl apply -k overlays/prod` brings up a working tracker"; no ingress means no tracker.
- **Hardcode Cloudflare Tunnel as the prod default.** Rejected: vendor-lock-in conflicts with the self-hosted, cluster-portable positioning. Cloudflare Tunnel is documented as one valid `INGRESS_TLS=external` recipe, not the default.
- **Use Traefik-as-Ingress-controller (not IngressRoute).** Considered. Lets a single overlay target Traefik clusters via the standard `Ingress` API. Rejected because it forfeits the middleware ergonomics that motivate choosing Traefik in the first place; operators who want vanilla `Ingress` use the second overlay.

## References

- ROADMAP v0.3 (Ingress via Traefik IngressRoute + cert-manager): [docs/ROADMAP.md](../ROADMAP.md)
- CLAUDE.md K8s naming and routing conventions: [.claude/CLAUDE.md](../../.claude/CLAUDE.md)
- ratatoskr K8s rules (`/announce` served by `unit3d-app`, not a separate daemon): [.claude/rules/k8s.md](../../.claude/rules/k8s.md)
- Traefik `IngressRoute` CRD: <https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/>
- cert-manager: <https://cert-manager.io/docs/>
- Kubernetes Ingress API: <https://kubernetes.io/docs/concepts/services-networking/ingress/>
- Gateway API: <https://gateway-api.sigs.k8s.io/>
- BitTorrent HTTP tracker protocol (BEP-3, announce response format): <https://www.bittorrent.org/beps/bep_0003.html>

### Follow-up commits (out of scope for this ADR)

- `docs(claude): hoist /announce middleware ban into rules` — promotes the body-rewriting ban from this ADR into `.claude/rules/k8s.md` as a hard rule. Until that commit lands, this ADR is the canonical reference for the constraint, and the `k8s-reviewer` agent reads it from here.
- ROADMAP v0.3 ingress wording rewrite (paired with the v0.4 storage rewording from ADR-0002).
