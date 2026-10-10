#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
image="${IMAGE:-ratatoskr/unit3d:dev}"
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
    --entrypoint php "$image" -r '
    foreach (["/app/public", "/app/config", "/app/vendor", "/etc/caddy/Caddyfile"] as $path) {
        if (is_writable($path)) { fwrite(STDERR, "Writable code/config: $path\n"); exit(1); }
    }
    if (ini_get("expose_php") || ini_get("display_errors") || ini_get("allow_url_include")) { exit(1); }
    foreach (["pdo_mysql", "redis", "intl", "bcmath", "gd", "zip", "exif", "Zend OPcache", "pcntl", "sodium"] as $ext) {
        if (!extension_loaded($ext)) { fwrite(STDERR, "Missing extension: $ext\n"); exit(1); }
    }
    echo "Immutable application code and PHP settings verified\n";'
docker run --rm --entrypoint sh "$image" -ec '
    test -z "$(find / -xdev -type f -perm /6000 2>/dev/null)"
    for tool in composer bun git pear pecl phpize phpdbg php-cgi mariadb mysql; do
        if command -v "$tool" >/dev/null; then echo "Unexpected runtime tool: $tool"; exit 1; fi
    done
    dpkg-query -W liblzma5 xz-utils'
python3 scripts/tests/http-security.py "$image"
echo IMAGE_SECURITY_RESULT=PASS
