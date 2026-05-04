# DISCLAIMER

## ⚠️ Infrastructure only

ratatoskr is a deployment stack — Dockerfiles, Compose files, Kubernetes manifests, and Helm charts. It does not host, index, distribute, or transmit any content. It is infrastructure in the same sense that a Nextcloud or Jellyfin image is infrastructure: what operators run on top of it is their responsibility alone.

## Operator responsibility

Deploying ratatoskr means you operate a BitTorrent tracker. You are solely and fully responsible for:

- The legality of every torrent your instance indexes or announces, under the laws of your jurisdiction and the jurisdiction(s) of your users and hosting provider.
- Copyright compliance, including DMCA safe-harbor obligations (17 U.S.C. § 512, US) and e-Commerce Directive notice-and-takedown obligations (EU Directive 2000/31/EC).
- GDPR or equivalent privacy-law compliance if your instance collects personal data (user accounts, IP addresses, access logs).
- Your uplink ISP's acceptable-use policy and your hosting provider's terms of service.

The maintainers of ratatoskr accept no liability for how operators use this stack.

## Legitimate use

Private BitTorrent trackers have many lawful applications:

- Distributing Linux distribution ISOs and open-source software releases within a community.
- Sharing scientific datasets, Wikipedia dumps, and other public-domain archives.
- A band or label distributing their own recordings to subscribers.
- A film production sharing dailies and review cuts with collaborators.
- An organization mirroring Creative Commons or public-domain archives.

No example in this repository — in code, documentation, commits, issues, or pull requests — assumes infringing content. Contributions that introduce such examples will be rejected.

## No facilitation of piracy

The maintainers do not condone copyright infringement. ratatoskr will not be developed in directions that primarily serve infringing use. This includes refusing to document configurations that suggest or optimize for illegal distribution.

## ✅ AGPL-3.0 obligations

ratatoskr is licensed under the [GNU Affero General Public License v3.0](./LICENSE), inherited from upstream [UNIT3D Community Edition](https://github.com/HDInnovations/UNIT3D).

Pulling the published image and applying the manifests unmodified does not trigger AGPL distribution obligations on operators.

If you fork the image, modify the source, and run it so that users interact with it over a network, AGPL §13 requires you to make the corresponding modified source available to those users. "Users" in this context includes anyone with network access to your running tracker instance — not just people you distribute binaries to.

## No warranty

This software is provided as-is, without warranty of any kind, express or implied. This includes, but is not limited to, implied warranties of merchantability or fitness for a particular purpose. In no event shall the maintainers be liable for any damages — direct, indirect, incidental, special, or consequential — arising from the use or inability to use this software, even if advised of the possibility of such damages. See AGPL-3.0 §§ 15–16 for the full warranty disclaimer.
