# 🌳 ratatoskr

> The messenger of Yggdrasil — Production-grade Kubernetes deployment for UNIT3D.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![UNIT3D](https://img.shields.io/badge/UNIT3D-v9.2.0-f46d5f.svg)](https://github.com/HDInnovations/UNIT3D)
[![PHP](https://img.shields.io/badge/PHP-8.4-777BB4.svg)](https://www.php.net/)
[![Laravel](https://img.shields.io/badge/Laravel-12-f4645f.svg)](https://laravel.com/)

A modern, opinionated deployment stack for [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D), built on **FrankenPHP**, packaged for **Docker**, **Kubernetes**, and **GitOps**.

> ⚠️ **Infrastructure only.** This repository provides deployment templates. Operators are fully responsible for the legality of content distributed on their instance. See [DISCLAIMER.md](./DISCLAIMER.md).

---

## ✨ Features

- 🐘 **FrankenPHP** runtime — single binary, worker mode, no nginx + php-fpm dance
- 📦 **Multi-level deployment** — from `docker compose up` to full GitOps
- 🔍 **MeiliSearch** wired in — fulltext torrent search out of the box
- 🔄 **GitOps-ready** — ArgoCD `ApplicationSet` template provided
- 🛡️ **Production hardening** — NetworkPolicies, PDB, HPA, SealedSecrets

---

## 🚀 Quick start

```bash
git clone https://github.com/John6810/ratatoskr.git
cd ratatoskr/compose
cp .env.example .env
docker compose up -d
```

Then open `http://localhost` and log in with the bootstrap owner credentials defined in your `.env`.

---

## 📚 Deployment levels

| Level | Use case | Status |
|---|---|---|
| **1. Docker Compose** | Local test, small self-host on a single VPS | 🚧 WIP |
| **2. Kustomize / K3s** | Single-node Kubernetes on a beefy VPS | 📋 Planned |
| **3. Helm + ArgoCD** | Multi-node production with GitOps | 📋 Planned |
| **4. Terraform** | Full IaC bootstrap (Hetzner, DigitalOcean, …) | 📋 Planned |

Each level has its own guide in [`docs/`](./docs).

---

## 🧱 Stack

| Component | Image / Version |
|---|---|
| App | `ghcr.io/john6810/unit3d:v9.2.0` (FrankenPHP) |
| Database | MariaDB 11 |
| Cache & queues | Redis 7 |
| Search | MeiliSearch v1.43 |

---

## 🗺️ Roadmap

- **v0.1.0** ✅ — Compose MVP (Dockerfile + working stack) — Released 2026-05-04
- **v0.2.0** ✅ — Backup & restore (mariadb-backup + Restic, restore drill, operator guide) — Released 2026-05-05
- **v0.3.0** ✅ — Kubernetes production overlay (Kustomize, HPA, NetworkPolicy, ArgoCD) — Released 2026-05-08
- **v0.4.0** ✅ — Documentation expansion & migration tool — Released 2026-05-08
- **v0.4.1** — S3 storage migration (upstream-PR-gated)
- **v0.5.0** — Helm chart + Gateway API parity
- **v1.0.0** — Terraform IaC + dedicated `/announce` daemon + full docs

The full version-by-version roadmap with scale envelopes is in [docs/ROADMAP.md](./docs/ROADMAP.md).

---

## 🤝 Contributing

PRs welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) (coming soon).

---

## 📜 License

[AGPL-3.0](./LICENSE) — same as upstream UNIT3D. If you fork and distribute, you must publish your changes.

---

<sub>Named after **Ratatoskr**, the squirrel who runs up and down Yggdrasil carrying messages between the realms — much like a tracker between its peers.</sub>
