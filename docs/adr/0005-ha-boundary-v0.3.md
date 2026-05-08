# ADR-0005: HA boundary at v0.3

- **Status**: Proposed
- **Date**: 2026-05-08
- **Deciders**: <leave blank for now>
- **Tags**: `ha`, `kubernetes`, `roadmap`

## Context

The v0.3 Kubernetes overlays (`dev`, `prod-rwo`, `prod-rwx`) ship a multi-tier architecture where some components scale horizontally and others are deliberately single-replica. Operators planning their deployment need explicit clarity on which components are HA at v0.3, which are single-replica by design constraint, and which are deferred to future ADRs.

Without an explicit HA boundary statement, operators discover gaps the hard way — provisioning hardware for "the whole stack to scale", then finding `unit3d-scheduler` is hard-pinned to one replica or `mariadb` doesn't lift to multi-master without an additional ADR. The cost of misaligned expectations runs from over-provisioning (cheap) to designing failover scenarios that ratatoskr cannot honor (expensive).

This ADR documents the v0.3 HA boundary component-by-component and signals which successor ADRs will lift specific components to multi-replica HA in later versions. Operators with scale envelopes beyond what v0.3 supports should align their adoption timeline with the relevant successor ADRs rather than fork ratatoskr to implement HA on top of unstable upstream patterns.

## Decision

Component-by-component HA status at v0.3:

| Component | v0.3 mode | Rationale | Future ADR |
|---|---|---|---|
| `unit3d-app` | Multi-replica HPA (prod-rwx); single-replica + Recreate (prod-rwo, dev) | Stateless web tier — already HA in prod-rwx | None planned |
| `unit3d-queue` | Multi-replica HPA, KEDA opt-in | Stateless workers — already HA | None planned |
| `unit3d-scheduler` | Single-replica HARD CONSTRAINT | Laravel `schedule:work` must run as a single global process | None planned (design constraint, not deferral) |
| `mariadb` | Single-replica StatefulSet | Galera complexity unjustified at v0.3 scale envelope | v0.7 — MariaDB Galera HA |
| `redis` | Single-replica StatefulSet (AOF) | Sentinel/Cluster operator burden unjustified at v0.3 | Future ADR (operator-demand-gated) |
| `meilisearch` | Single-replica StatefulSet | Upstream replication still experimental | Future ADR (when upstream stable) |
| `ingress-traefik` | Cluster-managed | Traefik install owned by operator, out of scope | None planned (out of scope) |

Each row is detailed below.

### `unit3d-app`

- **v0.3 mode**: Multi-replica with HPA in `prod-rwx` (min 2, max 10, CPU 70% + Memory 80%). Single-replica + `Recreate` strategy in `prod-rwo` and `dev` (RWO PVC cannot be multi-attached).
- **Rationale**: Stateless web tier. FrankenPHP worker mode, Laravel sessions in Redis, no sticky sessions needed (per [ADR-0003](./0003-ingress-controller-assumption.md)). Horizontal scaling is the natural design when the storage class supports RWX. PDB `minAvailable: 1` paired with HPA `minReplicas: 2` and RollingUpdate `maxUnavailable: 0` ensures zero-downtime rollouts and voluntary disruption tolerance.
- **Future ADR**: None planned — already HA in `prod-rwx`. Operators on RWO-only clusters who want HA must move to RWX (v0.4 may ship migration tooling for prod-rwo → prod-rwx).

### `unit3d-queue`

- **v0.3 mode**: Multi-replica with CPU HPA by default in `prod-rwx` (min 2, max 8, CPU 70%). Operators opt into Redis-queue-length-driven scaling via the [`keda-queue-scaler`](../../kustomize/components/keda-queue-scaler/) Component (commit `2cf8d80`).
- **Rationale**: Stateless queue workers. Jobs are picked up by surviving replicas during voluntary disruption. The `--max-time=3600` flag cycles workers naturally and graceful shutdown handles the in-flight job before SIGKILL. KEDA Component allows backlog-aware scaling for operators who find CPU a poor proxy for queue throughput at high tail.
- **Future ADR**: None planned — already HA. The KEDA Component itself may evolve (additional triggers, named-queue support) without a new ADR; it's a Kustomize Component with a stable opt-in surface.

### `unit3d-scheduler`

- **v0.3 mode**: Single-replica **HARD CONSTRAINT**. Set `replicas: 1` in `base/unit3d-scheduler/deployment.yaml` and pinned across all overlays. Cannot be patched up.
- **Rationale**: Laravel scheduler (`php artisan schedule:work`) must run as a single global process. Multi-replica = double-fire of every cron task, breaking idempotency assumptions for tasks like ratio recalculation, peer accounting, and snatched-stats updates. UNIT3D's scheduled tasks are not all written defensively against double-fire.
- **Future ADR**: **None planned**. Lock leader election (e.g. via Laravel's `withoutOverlapping()` with a Redis-backed mutex) is a per-task pattern, not an HA pattern. The scheduler dispatches but does not process work; "HA" for this component would mean leader-election across multiple scheduler pods, which adds complexity for a workload that fits comfortably in a single replica at any v0.3-supported scale.

### `mariadb`

- **v0.3 mode**: Single-replica StatefulSet. `prod-rwx` sizes resources to 500m-2 CPU / 1-4 GiB memory and 50 GiB PVC. `prod-rwo` runs the base 250m-1 CPU / 512Mi-2Gi at 10 GiB PVC.
- **Rationale**: Galera multi-master adds operational complexity (split-brain risk, recovery procedures, cluster bootstrap order, certification cluster behavior under network partition) that is not justified at the v0.3 scale envelope. Single-replica with proper sizing handles up to ~50K active users comfortably (the tracker workload is read-heavy with predictable write bursts on announce). The v0.2 backup pipeline (`mariadb-backup` + Restic + restore drill) covers the durability dimension; the recovery time objective at v0.3 is "minutes from snapshot", which is sufficient for self-hosted operators.
- **Future ADR**: **v0.7 — MariaDB Galera HA**, scoped per the ADR-0001 reopen note. Will document Galera bootstrap, certification quorum, the choice between mariadb-operator vs raw StatefulSet, and the upgrade path from prod-rwx single-replica → Galera. Operators planning >50K active users should align their adoption timeline with v0.7.

### `redis`

- **v0.3 mode**: Single-replica StatefulSet with AOF persistence enabled (`appendonly yes`).
- **Rationale**: Redis Sentinel topologies require sentinel quorum (3+ sentinel pods, separate from Redis pods), client-side failover library configuration in Laravel, and an awareness of split-brain during sentinel partition. Redis Cluster adds slot management and client-side cluster-aware drivers. Both add operator burden that is not justified for ratatoskr's Redis usage pattern: sessions (recoverable on user re-login), cache (recoverable from cold), queue backlog (in-flight jobs lost up to last AOF flush window). Loss of Redis is recoverable, not catastrophic — the scheduler will re-dispatch missed periodic tasks.
- **Future ADR**: A future ADR (un-versioned at this writing — operator-demand-gated) will document Redis Sentinel adoption when scale or operator demand drives the tradeoff. Likely co-scheduled with the Galera ADR if they land together (both involve quorum-aware infrastructure).

### `meilisearch`

- **v0.3 mode**: Single-replica StatefulSet, AOF-equivalent durability via Meili's snapshot mechanism.
- **Rationale**: Meilisearch's HA story is still maturing. Cluster replication is available behind an experimental flag at this writing; ratatoskr does not adopt experimental upstream features in production overlays. Search workloads tolerate brief unavailability — torrent search degrades gracefully to cached browse and the SQL `LIKE`-based fallback for unindexed queries. Re-indexing via `php artisan scout:import` after pod restart is the recovery path; the unit3d-migrate Job already runs `scout:sync-index-settings` to ensure schema consistency.
- **Future ADR**: A future ADR will track MeiliSearch HA adoption when upstream replication exits experimental status. Likely v0.6+ given the upstream timeline.

### `ingress-traefik`

- **v0.3 mode**: Cluster-managed. Operator's existing Traefik install handles its own HA topology.
- **Rationale**: ratatoskr ships an `IngressRoute` and supporting Middlewares + cert-manager `ClusterIssuer` + `Certificate` (per [`components/ingress-traefik`](../../kustomize/components/ingress-traefik/)). The Traefik controller pods themselves are operator-managed — typical Traefik installs run 2-3 replicas with a Service exposed via LoadBalancer or NodePort. ratatoskr does not bundle the Traefik install.
- **Future ADR**: **None planned**. Out of scope — this is a per-cluster infrastructure layer.

## Alternatives considered

- **Ship Galera HA at v0.3** — rejected per ADR-0001 reopen note. Galera operational complexity (split-brain risk, recovery procedures, cluster bootstrap order) outweighs the single-replica MariaDB ceiling at the v0.3 scale envelope. Deferred to v0.7.

- **Ship Redis Sentinel at v0.3** — rejected because Sentinel adds operator burden (sentinel quorum tuning, client-side failover library config) that single-replica AOF persistence avoids. Loss of Redis = recoverable session/queue impact, not catastrophic, given the v0.2 backup pipeline + restore drill.

- **Multi-replica scheduler with Redis-backed leader election** — rejected because Laravel's `scheduling.preventing-task-overlaps` mutex is a per-task pattern, not an HA pattern. The scheduler process itself is single-purpose (kick off due tasks every minute); leader election for a process that does virtually no work between cron evaluations is over-engineering.

## Consequences

- Operators planning >50K active users have a clear upgrade path: v0.7 Galera lifts the MariaDB ceiling. Sizing prod-rwx for that scale before v0.7 ships requires accepting single-replica MariaDB as the bottleneck.
- Operators planning >100K users on Redis-as-queue should anticipate the future Redis Sentinel ADR. Workloads that don't push Redis hard (sessions + cache only, no heavy queue backlog) can run single-replica Redis comfortably at much higher scale.
- The single-replica scheduler is a permanent design, not a v0.3 limitation. Operators relying on tight cron schedules need to plan scheduler resource sizing — the base 50m / 128Mi is sufficient for UNIT3D's default schedule frequency. Tasks dispatched by the scheduler scale with the queue worker pool.
- Each row's "Future ADR" column gives operators visibility into the v0.4-v1.0 HA roadmap. The roadmap is non-binding (versions can slip per [`docs/ROADMAP.md`](../ROADMAP.md) principles), but the dependency direction is explicit.
- This ADR is documentation-first — it does not introduce or modify manifests. The HA modes it describes are already implemented across base + the three v0.3 overlays.

## References

- [ADR-0001](./0001-database-deployment-topology.md) — Database deployment topology (MariaDB embedded vs external; reopen at v0.7 for Galera).
- [ADR-0002](./0002-storage-strategy-unit3d-storage.md) — Storage strategy (S3 hybrid for the 3 Storage-aware disks, RWX requirement for prod-rwx).
- [ADR-0003](./0003-ingress-controller-assumption.md) — Ingress controller assumption (Component-based decomposition, no sticky sessions at v0.3).
- [ADR-0004](./0004-secret-management.md) — Secret management (sealed-secrets default, ESO alternative).
- `39c0e1b` feat(kustomize): add overlays/prod-rwx
- `6f8c25f` feat(kustomize): add overlays/prod-rwo
- `755e1c6` feat(kustomize): add overlays/dev and bootstrap-app-key component
- `2cf8d80` feat(kustomize): add keda-queue-scaler Component (KEDA Redis queue length scaler for unit3d-queue)
- Laravel scheduler docs: <https://laravel.com/docs/scheduling>
- MariaDB Galera HA: <https://galeracluster.com/>
- Redis Sentinel: <https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/>
- Meilisearch experimental replication: <https://www.meilisearch.com/docs/learn/experimental/overview>

## Decision Log

(empty — populated by future amendments)
