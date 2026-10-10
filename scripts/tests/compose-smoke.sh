#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# The test fixture selects ratatoskr/unit3d:dev; build/tag it before running.
project="ratatoskr-compose-test-$RANDOM-$RANDOM"
compose=(docker compose --project-name "$project" --env-file compose/.env.test \
    --file compose/docker-compose.yml --file compose/docker-compose.test.yml)
cleanup() {
    rc=$?
    trap - EXIT
    docker rm -f "$project-init" >/dev/null 2>&1 || true
    if [ "$rc" != 0 ]; then
        "${compose[@]}" ps --all
        "${compose[@]}" logs --tail=50 unit3d unit3d-migrate
    fi
    "${compose[@]}" down --volumes --remove-orphans || rc=1
    if [ "$rc" = 0 ]; then echo COMPOSE_SMOKE_RESULT=PASS; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker image inspect ratatoskr/unit3d:dev >/dev/null
bash scripts/tests/image-security.sh
# Cancellation must interrupt an init wait, including in worker Pods with a
# long termination grace period. Exit 143 proves SIGTERM handling, not SIGKILL.
docker run -d --name "$project-init" --entrypoint php \
    -e RATATOSKR_STORAGE_PATH=/tmp/storage ratatoskr/unit3d:dev \
    /usr/local/lib/ratatoskr/lifecycle.php prepare >/dev/null
sleep 1
docker stop --time=3 "$project-init" >/dev/null
test "$(docker inspect --format '{{.State.ExitCode}}' "$project-init")" = 143
docker rm "$project-init" >/dev/null
echo LIFECYCLE_CANCELLATION_RESULT=PASS
# Registry authentication/downloads can time out before any test container
# exists. Retry only image acquisition, never a failed application startup.
for attempt in 1 2 3; do
    if "${compose[@]}" pull --policy missing --ignore-buildable; then break; fi
    if [ "$attempt" = 3 ]; then exit 1; fi
    echo "Image pull failed; retrying ($attempt/3)" >&2
    sleep 5
done
"${compose[@]}" up -d --wait --wait-timeout 180
"${compose[@]}" exec -T unit3d curl -fsS --max-time 10 -o /dev/null -w '%{http_code}\n' http://127.0.0.1/
"${compose[@]}" exec -T unit3d php -r '
foreach (["MARIADB_ROOT_PASSWORD", "MARIADB_BACKUP_PASSWORD", "DEFAULT_OWNER_PASSWORD"] as $key) {
    if (getenv($key)) { fwrite(STDERR, "Unexpected administrative credential: $key\n"); exit(1); }
}'
python3 scripts/tests/http-session.py "http://$("${compose[@]}" port unit3d 80)"
# A second run must preserve already seeded data instead of inserting duplicates.
"${compose[@]}" run --rm --no-deps unit3d-migrate
