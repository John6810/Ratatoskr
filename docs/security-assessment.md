# Security assessment — 2026-10-10

Scope: chart `0.5.0-alpha.4`, UNIT3D v9.2.0, FrankenPHP 1.13.0 / PHP 8.4.
This records implementation and observed tests, not a penetration test or approval
for Internet production. The production host, ingress, CNI, CSI and external
service destinations have not been provided or qualified.

## Image inventory

Local amd64 builds were scanned with Trivy 0.75.0 and its vulnerability database
updated 2026-10-10 at 01:03 UTC. Counts are **package/advisory occurrences**;
several packages from one source can repeat the same CVE. No ignore list or VEX
suppression was introduced. All severities and unfixed findings are scanned.

| Image target | HIGH | CRITICAL | Distinct HIGH/CRITICAL CVEs | Findings with an available fix, all severities |
|---|---:|---:|---:|---:|
| Web / queue / scheduler | 66 | 1 | 23 | 0 |
| Migration, short-lived | 82 | 9 | 29 | 0 |
| Backup / restore | 0 | 0 | 0 | 0 |
| MariaDB 11.8.9 | 0 | 0 | 0 | 0 |
| Redis 7.4.11 | 0 | 0 | 0 | 0 |
| MeiliSearch 1.43.1 | 0 | 0 | 0 | 0 |

Backup still reports 7 LOW, 11 MEDIUM and 1 UNKNOWN; MariaDB reports 7 LOW and
11 MEDIUM. Redis and MeiliSearch have no findings in this scan. Results depend
on the scanner database and package detection; absence of a finding is not proof
of absence of vulnerabilities. GitHub artifacts contain the full per-architecture
reports. Check [PR #5](https://github.com/John6810/Ratatoskr/pull/5) for the remote
run matching the revision being reviewed.

The previous web image had 82 HIGH / 9 CRITICAL. The reduction comes from removing
MariaDB client packages from long-lived HTTP/worker containers. PDO still uses
PHP's mysqlnd driver. The CLI remains in the separate migration image because
Laravel's initial schema import needs it. It is never exposed as an HTTP service.

## Remaining risk and triage

- **libxml2:** CVE-2026-6653 remains CRITICAL in Trivy. Debian describes the XML
  processing issue and its distribution status in the
  [Debian tracker](https://security-tracker.debian.org/tracker/CVE-2026-6653).
  Seven further HIGH libxml2 advisories remain. PHP XML functionality is retained
  for application compatibility. Untrusted-input reachability has not been fully
  audited; do not classify these as harmless because the runtime is non-root.
- **Migration client:** the extra six distinct CVEs belong to Debian's MariaDB
  client packages. [CVE-2026-44172](https://security-tracker.debian.org/tracker/CVE-2026-44172)
  concerns escaping with the big5 character set;
  [CVE-2026-49261](https://security-tracker.debian.org/tracker/CVE-2026-49261)
  concerns a server wsrep notification path. Package attribution alone does not
  establish reachability in this CLI-only image. The deployment uses UTF-8 and a
  separate MariaDB 11.8.9 server without Galera. Migration jobs still require
  trusted inputs, restricted network access and careful handling of credentials.
- **Other web findings:** util-linux, curl, GnuTLS, ACL, ncurses, Perl, systemd
  libraries and X11 libraries remain in the Debian dependency closure. Many
  occurrences repeat a source-package advisory. Removed SUID/SGID bits, dropped
  capabilities, no-new-privileges, read-only roots and scoped network access
  reduce attack opportunities; they do not replace patches or establish that
  every vulnerable code path is unreachable.

No fixed version is advertised for these installed distribution packages in the
recorded scan. Do not mix Debian suites or install incompatible libraries simply
to change the count. Rebuild and rescan when distribution fixes become available.
If the deployment's risk policy forbids any unresolved CRITICAL finding, this
build does not meet that policy and Internet production remains blocked.

## Implemented changes

- Applied all available Debian/Alpine security updates, including XZ
  `5.8.1-1+deb13u2`, which the previous severity-only gate missed.
- Preserved upstream UNIT3D source and its Composer constraints with reviewed
  dependency fixes. Rebuilt FrankenPHP's x/net and MariaDB's gosu helper with
  corrected dependencies. Fixed Restic's OpenTelemetry SDK 1.45.0 log-disclosure
  advisory as well as earlier Go dependency findings.
- Pinned upstream image digests. Rebuilds refresh distribution package layers;
  resulting artifacts must be pinned by digest when deployed. All six targets
  execute and scan on native amd64 and arm64 in CI. Full scans are retained;
  missing inventories or any available fix, including LOW/UNKNOWN, fail CI.
- Restricted Compose capabilities, filesystem writes and backend networking.
  Application source and Caddy configuration are root-owned. Removed build tools
  and SUID/SGID executable bits. Non-root MeiliSearch keeps its existing 1.43.1
  index format; this is not an upgrade to the latest feature release.
- Application containers do not receive database administrator credentials;
  long-lived workloads mask the initial-owner password. Only migrations retain
  that password for first seeding. The owner email remains available because
  UNIT3D uses it for backup notifications.
- Applied PHP disclosure/session settings, blocked direct script and dotfile
  requests, preserved uncompressed announce responses, and removed URI/headers
  from Caddy access logs to protect passkeys, cookies and authorization values.
- Scoped Helm policies to each release, narrowed DNS destinations, restricted
  Kubernetes API egress to real Service/endpoint IPs, added an explicit profile
  that blocks public HTTPS egress, and rejected production debug/wildcard proxy
  trust. HTTPS app URLs enable Secure cookies.
- Publication requires the image matrix plus deployment/recovery qualification,
  and supplies SBOM, provenance and Cosign signing. PRs never publish images.

## Evidence and outstanding production work

Local checks exercise malicious HTTP paths, access-log redaction, immutable code,
real owner login/session, CSRF rejection, Livewire search, repeat migrations,
Helm upgrades and failed-migration recovery, authenticated search, Kustomize key
bootstrap, 132-file RWO→RWX transfer and rollback, and physical encrypted
backup/restore. Network tests prove allowed database/cache/search connections and
rejected connections from another release and to a decoy on API port 6443.

The local RWX fixture uses three Kind nodes and static NFS 4.0 volumes. The CI
wrapper additionally exercises dynamic NFS CSI. Neither certifies the intended
production storage or network implementation. Backends remain single-instance;
a dependency rollout can interrupt service. No availability claim follows from
successful local tests.

Before Internet production: define actual ingress/proxy addresses and egress
destinations; enable and test TLS, appropriate login/announce limits, admin 2FA,
host patching and audit retention; verify off-host backup recovery; test the real
CSI/CNI and load; review remaining CVE reachability and record risk acceptance.
Protect URI/passkey data at every proxy and application logging layer. A strict
egress profile requires explicit SMTP, storage and metadata API allowances.

See [hardening procedures](security-hardening.md), [dependency maintenance](../docker/security/README.md)
and [test commands](../scripts/tests/README.md).
