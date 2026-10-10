#!/usr/bin/env bash
# Security-maintained official services, without changing their data formats.
set -euo pipefail
cd "$(dirname "$0")/../.."
for component in mariadb redis meilisearch; do
    docker buildx build --load --platform linux/amd64 --provenance=false \
        --file docker/dependencies/Dockerfile --target "$component" \
        --tag "ghcr.io/john6810/ratatoskr-$component:security-20261010" .
done
