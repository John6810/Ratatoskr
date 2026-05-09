# 🌳 ratatoskr

> The messenger of Yggdrasil — Production-grade Kubernetes deployment for UNIT3D.

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Latest release](https://img.shields.io/github/v/release/John6810/Ratatoskr?logo=github&label=release)](https://github.com/John6810/Ratatoskr/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/John6810/Ratatoskr/docker-build.yml?branch=main&logo=githubactions&label=CI)](https://github.com/John6810/Ratatoskr/actions/workflows/docker-build.yml)
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

Spin up the full UNIT3D stack locally with Docker Compose:

```bash
# 1. Clone
git clone https://github.com/John6810/Ratatoskr.git
cd Ratatoskr/compose

# 2. Configure — copy .env.example and replace EVERY CHANGEME value
cp .env.example .env
# Open .env in your editor; replace every CHANGEME value before continuing.

# 3. Build and start (--build compiles the FrankenPHP image on first run)
docker compose up -d --build

# 4. Open the tracker
# http://localhost:8080  (UNIT3D_PORT in .env)
```

The bootstrap admin account comes from `DEFAULT_OWNER_NAME`,
`DEFAULT_OWNER_EMAIL`, and `DEFAULT_OWNER_PASSWORD` in `.env` — those
values are seeded into the database on the first migration run.

---

## 🏗️ Deployment levels

| Level | Status | Audience |
|---|---|---|
| **1. Docker Compose** | ✅ v0.1.0 (2026-05-04) | Single-host, quick start |
| **2. K3s mono-node** | ✅ v0.3.0 — `kustomize/overlays/dev` | Single VPS with K8s |
| **3. Kubernetes production** | ✅ v0.3.0 — `overlays/prod-rwo`, `prod-rwx`, ArgoCD `ApplicationSet` | Multi-node, GitOps |
| **4. Helm chart** | 📋 v0.5.0 (planned) | Helm-native operators |
| **5. Terraform IaC** | 📋 v0.9.0 (planned) | Multi-provider VPS bootstrap |

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

## 📚 Documentation

Operator-facing docs cover deployment, upgrade, security, and observability:

- [📐 Architecture](docs/architecture.md) — Component graph, storage strategy, request flow (3 Mermaid diagrams)
- [🚀 Upgrade guide](docs/upgrade-guide.md) — Migration paths (Compose → K8s, prod-rwo → prod-rwx, UNIT3D version bumps)
- [🔒 Security hardening](docs/security-hardening.md) — Production hardening recipes (NetworkPolicy, secrets, TLS, container, DB)
- [📊 Monitoring](docs/monitoring.md) — Observability baseline (Prometheus + Grafana + Loki + Alloy)
- [⚡ Multi-queue scaling](docs/multi-queue-scaling.md) — KEDA multi-lane pattern (when single-queue is not enough)

Architecture decisions are recorded as ADRs under [`docs/adr/`](docs/adr/) (5 Accepted at v0.4.0).

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

Issues and pull requests welcome. Contribution guidelines will land alongside v0.5.0; until then, follow the existing commit style ([Conventional Commits](https://www.conventionalcommits.org/)) and the conventions visible in the repository.

---

## 📜 License

[AGPL-3.0](./LICENSE) — same as upstream UNIT3D. If you fork and distribute, you must publish your changes.

---

<sub>Named after **Ratatoskr**, the squirrel who runs up and down Yggdrasil carrying messages between the realms — much like a tracker between its peers.</sub>
