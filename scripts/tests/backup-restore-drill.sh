#!/usr/bin/env bash
# A real backup and restore drill using only newly created Docker resources.
set -euo pipefail
cd "$(dirname "$0")/../.."
BACKUP_IMAGE="${BACKUP_IMAGE:-ratatoskr-backup:validation}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.8}"
name="ratatoskr-drill-$RANDOM-$RANDOM"
created_network=0
created_data=0
created_repo=0
cleanup() {
    rc=$?
    trap - EXIT
    docker rm -f "$name-db" >/dev/null 2>&1 || true
    if [ "$created_data" = 1 ]; then docker volume rm "$name-data" >/dev/null || rc=1; fi
    if [ "$created_repo" = 1 ]; then docker volume rm "$name-repo" >/dev/null || rc=1; fi
    if [ "$created_network" = 1 ]; then docker network rm "$name" >/dev/null || rc=1; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker image inspect "$BACKUP_IMAGE" >/dev/null
docker network create "$name" >/dev/null
created_network=1
docker volume create "$name-data" >/dev/null
created_data=1
docker volume create "$name-repo" >/dev/null
created_repo=1
db_password="$(openssl rand -hex 24)"
restic_password="$(openssl rand -hex 24)"
docker run --rm --user 0 --entrypoint sh -v "$name-repo:/repository" "$BACKUP_IMAGE" \
    -c 'chown mysql:mysql /repository'
docker run -d --name "$name-db" --network "$name" -v "$name-data:/var/lib/mysql" \
    -e "MARIADB_ROOT_PASSWORD=$db_password" -e MARIADB_DATABASE=unit3d "$MARIADB_IMAGE" >/dev/null
for attempt in $(seq 1 90); do
    if docker exec "$name-db" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then break; fi
    sleep 2
done
docker exec "$name-db" healthcheck.sh --connect --innodb_initialized
docker exec -e "MYSQL_PWD=$db_password" "$name-db" mariadb -uroot unit3d -e \
    'CREATE TABLE users (id INT PRIMARY KEY); INSERT INTO users VALUES (1); CREATE TABLE torrents (id INT PRIMARY KEY);'

args=(--rm --network "$name" -v "$name-repo:/repository" \
    -e RESTIC_REPOSITORY=/repository -e "RESTIC_PASSWORD=$restic_password" \
    -e "MARIADB_HOST=$name-db" -e MARIADB_USER=root -e "MARIADB_PASSWORD=$db_password" \
    -e BACKUP_PRUNE=false)
docker run "${args[@]}" -v "$name-data:/var/lib/mysql:ro" "$BACKUP_IMAGE" backup
docker run "${args[@]}" "$BACKUP_IMAGE" restore-test
docker run "${args[@]}" "$BACKUP_IMAGE" bash -c '
    set -eu
    mkdir /tmp/restore-target
    echo original > /tmp/restore-target/original
    TARGET_DIR=/tmp/restore-target RESTORE_FORCE=true restore latest
    test -f /tmp/restore-target/ibdata1
    test "$(cat /tmp/restore-target/.ratatoskr-before-restore-*/original)" = original
'
echo "BACKUP_RESTORE_RESULT=PASS"
