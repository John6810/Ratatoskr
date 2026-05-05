---
name: restore-drill
description: Run the ratatoskr backup pipeline restore drill — pulls the latest snapshot from the configured Restic repository, prepares it with mariadb-backup, spawns an ephemeral mariadbd inside the unit3d-backup container, and asserts the bootstrap admin sentinel row count. Gates any commit that touches `scripts/backup*.sh`, `scripts/restore*.sh`, `docker/backup/**`, `compose/docker-compose.backup.yml`, or `compose/.env.backup.example`. The drill must pass before the commit is allowed; on failure, surface the drill output and refuse to proceed. Uses the working-tree version of restore-test.sh, not HEAD — the script being committed is the one that runs.
allowed-tools: Bash(docker compose:*), Bash(docker ps:*), Bash(docker images:*), Bash(test:*), Bash(grep:*), Bash(rg:*), Read, Glob
---

# Restore drill

Verify the v0.2 backup pipeline produces a restorable artifact end-to-end. A backup that has never been restored is a guess. This skill enforces that any change touching the backup tooling has been drilled before it lands on `main`.

## When to invoke

Run this skill before staging or committing any change that touches:

- `scripts/backup.sh`
- `scripts/restore.sh`
- `scripts/restore-test.sh`
- `docker/backup/**` (the backup image)
- `compose/docker-compose.backup.yml` (profile, mounts, secrets)
- `compose/.env.backup.example` (env var renames break backup.sh silently)

Doc-only changes (`docs/backup-restore.md`, `compose/README.md`) do **not** trigger the drill — documentation cannot break the pipeline.

The skill is also useful out-of-band:

- After a UNIT3D bump (the schema may add tables the drill's COUNT(*) hits)
- After a MariaDB bump (mariadb-backup version-locks to the server major)
- Weekly in production (the restore-test container can be invoked from cron alongside the backup itself)

## Conventions for this skill

- **No bypass.** There is no `--skip-drill` flag, no `[skip-drill]` commit-message convention. If an operator truly needs to commit something without drilling (urgent typo fix in a comment), `git commit --no-verify` is the native escape hatch — but the skill does not surface it.
- **No cooldown.** Even if the drill passed two minutes ago, it re-runs. Skipped drills are exactly the failure mode this skill exists to prevent.
- **Working-tree semantics.** The drill exercises `scripts/restore-test.sh` and `scripts/restore.sh` as they appear in the working tree, not as committed at `HEAD`. The point is to test what is about to be committed.
- **Stack must be up.** The skill does not start or tear down services. If the Compose stack is not running, abort with an actionable error and let the operator decide.

## Pre-flight checks

Run these in order. Stop at the first failure with the actionable message shown.

### 1. Compose stack is running

```bash
docker compose --project-name ratatoskr ps --filter status=running --format '{{.Service}}' \
  | grep -q '^mariadb$'
```

If the stack is not running:

```
[restore-drill] Compose stack is not running.
[restore-drill] Bring it up first:
[restore-drill]   cd compose && docker compose up -d --wait
[restore-drill] Then re-run the drill.
```

Abort. Do not auto-start the stack — pulling images, running migrations, and seeding can take 60+ seconds and may surface unrelated failures that mask the drill outcome.

### 2. Backup secrets are populated

```bash
test -s compose/secrets/restic_password && \
test -s compose/secrets/mariadb_backup_password
```

If either is missing or empty:

```
[restore-drill] Backup secrets are missing or empty.
[restore-drill] Required files:
[restore-drill]   compose/secrets/restic_password
[restore-drill]   compose/secrets/mariadb_backup_password
[restore-drill] See docs/backup-restore.md "One-time setup" for generation steps.
```

Abort.

### 3. `.env.backup` is configured

```bash
test -s compose/.env.backup
```

If missing:

```
[restore-drill] compose/.env.backup is missing.
[restore-drill] Copy the example and fill in:
[restore-drill]   cp compose/.env.backup.example compose/.env.backup
[restore-drill] Set RESTIC_REPOSITORY, B2_* (or backend-specific creds), MARIADB_USER.
```

Abort.

### 4. At least one snapshot exists in the Restic repository

```bash
docker compose \
  --project-name ratatoskr \
  -f compose/docker-compose.yml \
  -f compose/docker-compose.backup.yml \
  --profile backup run --rm \
  unit3d-backup restic snapshots --tag ratatoskr-mariadb --json \
  | grep -q '^\['
```

The drill cannot validate a restore path if there is nothing to restore. If the `restic snapshots` output is empty (`[]`) or fails:

```
[restore-drill] No snapshots found in repository.
[restore-drill] Run a backup first:
[restore-drill]   docker compose -f docker-compose.yml -f docker-compose.backup.yml \
[restore-drill]       --profile backup run --rm unit3d-backup
[restore-drill] Then re-run the drill.
```

Abort.

## Workflow

### 1. Build the backup image (only if missing)

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep -q '^ratatoskr/unit3d-backup:dev$' \
  || docker compose \
       --project-name ratatoskr \
       -f compose/docker-compose.yml \
       -f compose/docker-compose.backup.yml \
       --profile backup build unit3d-backup
```

The build is a no-op when the image already exists locally. If the operator's commit modifies `docker/backup/Dockerfile`, the cached image is from the prior version — Compose will rebuild from cache layers when the build invocation runs against the new Dockerfile. Force a rebuild with `--no-cache` only if the operator asks (the cached layers are usually correct; an explicit rebuild is opt-in).

### 2. Run the drill against the working-tree scripts

The three pipeline scripts (`backup.sh`, `restore.sh`, `restore-test.sh`) are
`COPY`-ed into the backup image at build time. Without overriding, the version
that runs is whatever was baked at the last `docker build`, which is neither
working-tree nor `HEAD`. The skill bind-mounts the host scripts on top of the
image-installed copies so the drill always exercises the version about to be
committed:

```bash
docker compose \
  --project-name ratatoskr \
  -f compose/docker-compose.yml \
  -f compose/docker-compose.backup.yml \
  --profile backup run --rm \
  -v "$(pwd)/scripts/backup.sh:/usr/local/bin/backup:ro" \
  -v "$(pwd)/scripts/restore.sh:/usr/local/bin/restore:ro" \
  -v "$(pwd)/scripts/restore-test.sh:/usr/local/bin/restore-test:ro" \
  unit3d-backup restore-test
```

The bind mounts target the install paths set by the Dockerfile (no `.sh`
suffix in the image). They are read-only — the drill cannot modify the host
scripts, even on a misbehaving container.

This means the backup image only has to be rebuilt when something *outside*
the three scripts changes (`docker/backup/Dockerfile`, `docker/backup/entrypoint.sh`,
the base MariaDB pin, the Restic version pin). Edits to the scripts
themselves are picked up immediately, no rebuild needed.

Capture stdout + stderr. Capture the exit code.

### 3. Interpret the result

**Exit 0 — drill passed.** Proceed:

```
[restore-drill] PASS — pipeline produces a restorable snapshot.
[restore-drill] users count, torrents count, sentinel asserted.
[restore-drill] Commit may proceed.
```

**Exit non-zero — drill failed.** Refuse the commit:

```
[restore-drill] FAIL — the latest snapshot is not restorable end-to-end.
[restore-drill] Commit blocked.
[restore-drill]
[restore-drill] Drill output (last 30 lines):
[restore-drill] <captured stderr>
[restore-drill]
[restore-drill] Investigate before committing. Common causes:
[restore-drill]   - Schema change broke the COUNT(*) sentinel
[restore-drill]   - mariadb-backup --prepare failed (datadir corruption in the snapshot)
[restore-drill]   - Ephemeral mariadbd refused to start (version mismatch?)
[restore-drill]   - DB user password changed without snapshot rotation
```

Surface the last ~30 lines of drill output to the operator. Do not paste hundreds of lines — the operator can re-run the drill manually for full detail.

## Pitfalls

- **Modifying `restore-test.sh` itself**: the bind-mount strategy in workflow §2 means the in-progress script is what runs. If the edit is broken, the drill fails and the commit is rightfully blocked. Iterate locally outside the skill — invoke the same `docker compose ... run --rm -v ... unit3d-backup restore-test` command shown in §2 — until the script is stable, then stage and commit. There is no shortcut, by design.

- **Stack with stale credentials**: if the operator changed `compose/secrets/mariadb_backup_password` after the running MariaDB was bootstrapped, the backup user's password in MariaDB no longer matches the secret file. `restic snapshots` succeeds but `restore-test` fails at the prepare step. Fix: re-run the GRANT statement from `docs/backup-restore.md` "One-time setup" with the new password.

- **No snapshots on a fresh deployment**: the precondition check catches this and points the operator at the backup command. The drill itself never starts in this case.

- **Running against the wrong project name**: the skill assumes `--project-name ratatoskr` (set as `name: ratatoskr` in `compose/docker-compose.yml`). Operators who renamed the project for any reason will hit a "stack not running" error when the stack actually is up under a different name. The fix is to keep the project name as shipped, or to override the `--project-name` argument across all compose invocations consistently.

- **Restic repo lock contention**: a concurrent backup or prune holding the repo lock makes the drill's `restic snapshots` and `restic dump` calls fail. The drill output mentions the lock holder. Wait for the concurrent operation to complete or run `restic unlock` if the holder is genuinely stale.

## After a successful drill

The skill does not stage or commit anything. It only signals "go" or "no-go" for the commit the operator is about to make. The operator runs `git add` and `git commit` themselves. This is intentional: the skill is a guard, not a workflow driver.

## What this skill does not do

- It does not run the drill against multiple snapshots (only `latest`). Backfill regressions are out of scope.
- It does not test cross-major restore (forbidden anyway — see `docs/backup-restore.md` operational footguns).
- It does not run prune. Restic prune is a separate concern; running it from the drill would conflate verification with maintenance.
- It does not validate the threat-model claims (e.g. encryption is on, `RESTIC_PASSWORD` is non-empty). Those checks live in `security-auditor`.
