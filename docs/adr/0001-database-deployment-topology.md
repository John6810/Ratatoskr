# ADR-0001: Database deployment topology — embedded StatefulSet vs external managed

- **Status**: Accepted
- **Date**: 2026-05-06
- **Deciders**: <leave blank for now>
- **Tags**: `database`, `kubernetes`, `topology`

## Context

ratatoskr targets four progressive deployment levels (Compose → K3s → multi-node K8s → Terraform IaC). At every level, MariaDB is on the critical path: UNIT3D's primary store, the source of truth backed up by the v0.2 pipeline, and the dependency that gates the migration Job before app pods start.

The v0.3 Kubernetes overlay must pick a default deployment topology for MariaDB. Two operator profiles exist in the wild:

- **Self-hosted, all-in-one.** A 1-3 node K3s/K8s cluster, no external managed services. The default ratatoskr persona — the same operator who ran v0.1 Compose on a 4 GB VPS, now scaling out. Wants `kubectl apply -k overlays/prod` to bring up a working tracker, DB included.
- **Existing managed DB.** Operators already on AWS RDS, Aiven, OVH, or a self-managed MariaDB Galera cluster outside the Kubernetes cluster. They want to point ratatoskr at an external endpoint and disable the embedded DB.

v0.7 plans MariaDB scale (Galera or async replicas). v0.3 stays single-instance — the goal is to land production K8s, not to solve HA DB at the same time. <!-- VERIFY: confirm this scope split with the user; ROADMAP v0.7 wording supports it but the boundary should be explicit. -->

The v0.2 backup pipeline streams `mariadb-backup --backup` from the running server. This requires shell access to the data dir, which an embedded StatefulSet provides cleanly via a sidecar or a sibling Job in the same namespace. Managed DBs typically expose only the SQL endpoint, not the data dir — operators on managed DB use the provider's own backup mechanism instead. The Decision section makes this boundary explicit for the operator guide.

## Decision

Ship MariaDB as an **embedded StatefulSet by default**, with a single-replica `mariadb` workload in the `unit3d` namespace, persistent volume via the cluster's default `StorageClass`. Make it **toggleable** through a Kustomize overlay component (or Helm value at v0.5): operators who run managed DB drop the StatefulSet and instead populate the `mariadb-secrets` Secret + connection env vars on `unit3d-app`/`unit3d-queue`.

Both paths share the same DNS name (`mariadb.unit3d.svc.cluster.local`) so application manifests are topology-agnostic. The Service kind differs by topology: the embedded StatefulSet sits behind a regular **`ClusterIP`** Service, and external managed DB is exposed via an **`ExternalName`** Service that aliases the provider endpoint. A **headless** Service is intentionally not used at v0.3 — that pattern becomes relevant only at v0.7 when MariaDB Galera (or a multi-replica topology) needs per-pod DNS for client-side routing.

The v0.2 backup pipeline (`ratatoskr-backup` image) applies to the **embedded path only**: `mariadb-backup` requires shell access to the data dir, which managed DB providers do not expose. Operators on managed DB must use their provider's backup mechanism instead; the operator guide documents this boundary explicitly.

## Consequences

### Positive
- Zero-config path for the default ratatoskr persona: `kubectl apply -k overlays/prod` brings up DB + app together.
- Existing v0.2 backup pipeline keeps working unchanged in the embedded path (backup container reaches the data dir via a sidecar or sibling Job).
- App manifests stay identical across topologies — only the Service binding changes.
- Honest with the multi-level promise: same primitives at level 2, 3, and 4.

### Negative
- StatefulSet single-replica is not HA. A node failure during the window between MariaDB pod restart and PVC reattachment is a hard outage. Acceptable for v0.3's scale envelope (5K–10K active users, 3-node cluster) but documented as a known limitation.
- Operators with managed DB must wire the connection themselves; we provide examples but don't validate against every provider.
- Storage class portability: `csi-rawfile`-shaped clusters and cloud-provider CSI drivers behave differently around volume expansion and restore. <!-- VERIFY: pick the actual default in the prod overlay — don't hardcode a name, rely on the cluster default StorageClass and document the requirement. -->
- **No connection pooler in v0.3.** Each FrankenPHP worker process and each queue worker holds its own MariaDB connection. With multiple replicas of `unit3d-app` and `unit3d-queue`, aggregate connection count can saturate MariaDB's `max_connections` (default 151) on busy trackers. Mitigation deferred to v0.7 (ProxySQL or operator-managed pooling if mariadb-operator is adopted). Documented as a known limitation in the operator guide. <!-- VERIFY: confirm exact FrankenPHP worker → DB connection ratio with the laravel-unit3d-expert before publishing the operator guide. -->

### Neutral
- Decision deferred for v0.7 (Galera vs replicas) is documented; v0.3 does not preclude either future path.

## Alternatives considered

- **Managed-DB only (no embedded option).** Rejected: forces every operator to provision external DB, breaks the multi-level promise, raises the floor below the K3s tier.
- **Embedded-only (no managed toggle).** Rejected: blocks operators who already pay for HA managed DB and would have to run a second redundant instance to use ratatoskr.
- **mariadb-operator ([mariadb.com](https://mariadb.com)).** Considered. Provides CRD-managed StatefulSets, native physical backup primitives, and Galera/replica scale paths out of the box. Rejected for v0.3: a cluster-wide CRD dependency contradicts ratatoskr's minimal-moving-parts philosophy at single-replica scale, and adds an operator-install prerequisite to the prod overlay. Reopen in v0.7 when HA topology (Galera or async replicas) justifies the dependency. <!-- VERIFY: re-open this in the v0.7 ADR when DB scale is on the table. -->
- **Other DB operators (percona-operator, KubeDB, etc.).** Same reasoning as mariadb-operator at v0.3 — operator-install prerequisite. Out of scope for v0.7 evaluation as well: ratatoskr targets MariaDB specifically (matches upstream UNIT3D), so a MariaDB-native operator is the natural reopen candidate.
- **Bitnami MariaDB Helm chart as a subchart.** Relevant for v0.5 (Helm), not v0.3 (Kustomize). Postponed; the v0.3 StatefulSet is the source of truth that the v0.5 chart will mirror.

## References

- ROADMAP v0.3: <https://github.com/John6810/Ratatoskr/blob/main/docs/ROADMAP.md#v030--kubernetes-production-overlay-> <!-- VERIFY: anchor exact text after the section is rendered. -->
- ROADMAP v0.7 (DB scale): same file, section "v0.7.0 — Database Scale".
- v0.2 backup pipeline: [docs/backup-restore.md](../backup-restore.md)
- UNIT3D `.env.example` DB block: <https://github.com/HDInnovations/UNIT3D/blob/master/.env.example>
