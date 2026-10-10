# ADR-0007: Dependency-aware migrations and persistent credentials

- **Status**: Accepted
- **Date**: 2026-10-10
- **Tags**: `helm`, `kustomize`, `migrations`, `secrets`

## Context

A pre-install migration hook cannot use ordinary release resources that Helm
has not created yet. Post-install hooks combined with `--wait` can also deadlock
when application readiness requires a migrated database. Recreating credential
hooks during upgrades can invalidate persistent database credentials and APP_KEY.

## Decision

Use an ordinary Job named for the Helm revision. Its initializer prepares writable
storage and waits for dependencies. Each application workload waits for that exact
Job's successful completion using an init container and a narrowly scoped Role.
Only the init container mounts the projected API credentials. Keep the current
Job without TTL so restarted Pods can verify it; replace it on the next upgrade.

Create chart-managed Secrets only when absent, using Helm's cluster-side lookup.
Validate existing ownership and key names, preserve original values, and refuse
bootstrap regeneration on upgrade. Offline GitOps rendering requires externally
managed Secrets. Password rotation is a separate coordinated server/client change.

Kustomize uses the same lifecycle implementation with its static migration Job
name. Operators stop app/queue/scheduler, delete the old Job, apply the updated
overlay, and wait for the new Job before normal service resumes. Automatic GitOps
upgrades need explicit orchestration; an old completed Job must not authorize a
new application version. This is not supplied by the current ApplicationSet.

RWO consumers share one node through required affinity. RWX app/queue workloads
roll with zero unavailable replicas; scheduler stays single-replica/Recreate.

## Consequences

- Fresh installs can provision dependencies while application processes remain gated.
- Failed migrations block new workloads, with logs retained for diagnosis.
- RWO upgrades have downtime. RWX migrations must remain compatible with old Pods.
- Helm rollback does not reverse schema changes; restore is a separate operation.
- API access and volume scheduling must be tested on the operator's CNI and CSI.
- Helm client-side rendering cannot verify Secret reuse. Integration tests must
  install, upgrade, deliberately fail a migration, and recover against real storage.

## Alternatives

Making every dependency a hook complicates ownership and deletion. Post-install
hooks conflict with waiting for database-dependent application health. Running
migrations in every application Pod introduces competing schema writers. A single
ordinary Job with explicit startup gating avoids those failure modes.
