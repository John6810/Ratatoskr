# Third-party licenses

ratatoskr is licensed under [AGPL-3.0](./LICENSE), inherited from upstream UNIT3D.

The deployed stack and the ratatoskr-backup image embed the following
third-party software, each governed by its own license:

| Component | Version (at v0.2.0) | License | Source |
|---|---|---|---|
| UNIT3D Community Edition | v9.2.0 | AGPL-3.0 | https://github.com/HDInnovations/UNIT3D |
| FrankenPHP | 1-php8.4 (Caddy bundled) | Apache-2.0 | https://github.com/dunglas/frankenphp |
| MariaDB Server | 11.8 (currently 11.8.6, LTS EOL 2028-06-04) | GPL-2.0 | https://github.com/MariaDB/server |
| Redis | 7-alpine (currently 7.4.8) | RSALv2 / SSPLv1 dual¹ | https://github.com/redis/redis |
| MeiliSearch | v1.43 | MIT | https://github.com/meilisearch/meilisearch |
| Restic | 0.18.1 | BSD-2-Clause | https://github.com/restic/restic |
| Laravel (UNIT3D dep) | 12.x | MIT | https://github.com/laravel/laravel |

¹ Redis 7.4+ uses a dual RSALv2 / SSPLv1 license — neither is OSI-approved
and both restrict managed-service redistribution. Earlier Redis versions
(≤ 7.2) were BSD-3-Clause. Redis 8.x adds AGPLv3 as a third option.
Operators with compliance requirements barring RSAL/SSPL can switch to
[Valkey](https://valkey.io/) (BSD-3-Clause, Linux Foundation fork of
Redis 7.2) or [KeyDB](https://github.com/Snapchat/KeyDB) (BSD-3-Clause).
ratatoskr ships upstream Redis as the default; switching is a one-line
change in `compose/docker-compose.yml`.

## AGPL §13 in practice

ratatoskr inherits AGPL-3.0 from upstream UNIT3D. Vanilla pulls of the
published images (`ghcr.io/john6810/unit3d`, `ghcr.io/john6810/ratatoskr-backup`)
do not trigger AGPL distribution obligations on the operator. Forking and
distributing modified images does — at minimum, publish the modified source
under AGPL-3.0 and provide a network-accessible link to it from the modified
service (see [DISCLAIMER.md](./DISCLAIMER.md)).

## Compatibility

The combined work is distributed under AGPL-3.0. Per FSF guidance:

- AGPL-3.0 + GPL-2.0 (MariaDB): compatible when distributed under AGPL-3.0
- AGPL-3.0 + Apache-2.0 (FrankenPHP, Caddy): compatible
- AGPL-3.0 + MIT (MeiliSearch, Laravel): compatible
- AGPL-3.0 + BSD-2-Clause (Restic): compatible
- AGPL-3.0 + RSALv2/SSPLv1 (Redis 7.4): not OSI-clean. Operators with
  strict OSI requirements should switch the redis service to Valkey.

## How this list is maintained

Updated on every ratatoskr release that bumps a pinned component. PRs welcome
to add entries (e.g. when a new dependency lands) or correct license fields.
The `check-upstream-versions` skill drives version verification at release
prep time.
