#!/usr/bin/env python3
"""Exercise the real image/Caddyfile against mounted hostile public files."""
import json
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def docker(*args):
    return subprocess.check_output(['docker', *args], text=True, stderr=subprocess.STDOUT)


def request(base, path, token):
    req = urllib.request.Request(base + path, headers={
        'Accept-Encoding': 'gzip, br, zstd', 'Referer': 'https://example.invalid/' + token,
        'Authorization': 'Bearer ' + token, 'Cookie': 'session=' + token,
    })
    try:
        response = urllib.request.urlopen(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


name = 'ratatoskr-http-security-' + secrets.token_hex(6)
token = secrets.token_hex(24)
created = False
with tempfile.TemporaryDirectory(prefix=name) as directory:
    directory = Path(directory)
    # The stub replaces only the application worker; the shipped Caddyfile is
    # unchanged. Compose separately exercises the real Laravel application.
    fixtures = {
        'worker.php': '<?php while (frankenphp_handle_request(function () { header("Content-Type: text/plain"); echo "d14:failure reason1024:".str_repeat("x",1024)."e"; })) {}',
        'canary.php': '<?php echo "EXECUTED_UNTRUSTED_PHP";',
        'hidden': 'PRIVATE_DOTFILE',
        'asset.txt': 'PUBLIC_ASSET',
    }
    mounts = {
        'worker.php': '/app/public/frankenphp-worker.php',
        'canary.php': '/app/public/security-canary.php',
        'hidden': '/app/public/.security-canary',
        'asset.txt': '/app/public/security-asset.txt',
    }
    args = ['run', '-d', '--name', name, '--read-only', '--no-healthcheck',
            '--cap-drop', 'ALL', '--cap-add', 'NET_BIND_SERVICE',
            '--security-opt', 'no-new-privileges', '--pids-limit', '128',
            '--sysctl', 'net.ipv4.ip_unprivileged_port_start=80',
            '-p', '127.0.0.1::80', '--tmpfs', '/tmp:rw,noexec,nosuid,nodev,size=16m',
            '--tmpfs', '/data/caddy:uid=33,gid=33,size=16m',
            '--tmpfs', '/config/caddy:uid=33,gid=33,size=16m']
    for filename, target in mounts.items():
        source = directory / filename
        source.write_text(fixtures[filename])
        source.chmod(0o644)
        args += ['--mount', f'type=bind,src={source},dst={target},readonly']
    try:
        docker(*args, sys.argv[1])
        created = True
        base = 'http://' + docker('port', name, '80').strip()
        for attempt in range(40):
            try:
                status, headers, body = request(base, '/security-asset.txt', token)
                assert status == 200 and body == b'PUBLIC_ASSET'
                break
            except (OSError, AssertionError):
                if attempt == 39:
                    raise
                time.sleep(0.25)
        for path in ['/security-canary.php', '/security-canary.php/extra',
                     '/security-canary%2ephp', '/SECURITY.PHP', '/.security-canary',
                     '/%2esecurity-canary', '/build/.env', '/frankenphp-worker.php']:
            status, headers, body = request(base, path, token)
            assert status == 404, (path, status)
            assert b'EXECUTED_UNTRUSTED_PHP' not in body and b'PRIVATE_DOTFILE' not in body
        for path in ['/announce?passkey=' + token, '/announce/' + token + '?passkey=' + token]:
            status, headers, body = request(base, path, token)
            assert status == 200
            assert body == b'd14:failure reason1024:' + b'x' * 1024 + b'e'
            assert not headers.get('Content-Encoding'), 'Announce was compressed'
            assert not headers.get('Server') and not headers.get('X-Powered-By')
            assert headers.get('X-Content-Type-Options') == 'nosniff'
            assert headers.get('Referrer-Policy') == 'no-referrer'
        logs = docker('logs', name)
        assert token not in logs, 'Credential marker leaked into logs'
        access = [json.loads(line) for line in logs.splitlines() if line.startswith('{')]
        access = [entry for entry in access if 'request' in entry]
        assert access, 'No access logs collected; redaction not verified'
        assert all('uri' not in e['request'] and 'headers' not in e['request'] for e in access)
        print('HTTP_SECURITY_RESULT=PASS: hostile files blocked, announce intact, credentials redacted')
    finally:
        if created:
            docker('rm', '-f', name)
