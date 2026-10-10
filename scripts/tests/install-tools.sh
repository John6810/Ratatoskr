#!/usr/bin/env bash
# Linux amd64 CI tools, verified against the release checksums.
set -euo pipefail
destination="${1:?Usage: install-tools.sh destination-directory}"
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
work="$(mktemp -d -t ratatoskr-tools-XXXXXX)"
trap 'rm -rf "$work"' EXIT
fetch() {
    curl --fail --location --retry 3 "$1" --output "$work/download"
    printf '%s  %s\n' "$2" "$work/download" | sha256sum --check --status
}
fetch https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz fc307327959aa38ed8f9f7e66d45492bb022a66c3e5da6063958254b9767d179
tar -xzf "$work/download" -C "$work" linux-amd64/helm
install -m 0755 "$work/linux-amd64/helm" "$destination/helm"
fetch https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.8.3/kustomize_v5.8.3_linux_amd64.tar.gz cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61
tar -xzf "$work/download" -C "$work" kustomize
install -m 0755 "$work/kustomize" "$destination/kustomize"
fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz 9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
tar -xzf "$work/download" -C "$work" kubeconform
install -m 0755 "$work/kubeconform" "$destination/kubeconform"
fetch https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
install -m 0755 "$work/download" "$destination/kind"
