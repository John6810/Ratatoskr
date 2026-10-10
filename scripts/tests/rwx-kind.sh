#!/usr/bin/env bash
# Disposable, three-node NFS integration test. CSI by default; STATIC_NFS=1
# explicitly selects precreated NFS volumes without testing CSI provisioning.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${UNIT3D_TEST_IMAGE:?Build the current application image first}"
cluster="ratatoskr-rwx-$RANDOM-$RANDOM"
work="$(mktemp -d -t ratatoskr-rwx-kind-XXXXXX)"
export KUBECONFIG="$work/kubeconfig"
export RWX_STORAGE_CLASS=ratatoskr-nfs
created=0
cleanup() {
    rc=$?
    trap - EXIT
    if [ "$created" = 1 ]; then
        if [ "$rc" != 0 ]; then kubectl get pods -A -o wide || true; fi
        kind delete cluster --name "$cluster" || rc=1
    fi
    rm -rf "$work"
    if [ "$rc" = 0 ]; then echo RWX_KIND_RESULT=PASS; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if kind get clusters | grep -Fxq "$cluster"; then
    echo 'Refusing to reuse an existing cluster' >&2
    exit 1
fi
created=1
kind create cluster --name "$cluster" --config scripts/tests/fixtures/kind-multinode.yaml --wait 120s \
    --image kindest/node:v1.32.0@sha256:c48c62eac5da28cdadcf560d1d8616cfa6783b58f0d94cf63ad1bf49600cb027
kind load docker-image "$UNIT3D_TEST_IMAGE" --name "$cluster"
# Reuse locally cached dependencies without downloading them again. Import only
# the runtime platform; registry archives can also contain provenance manifests.
cached_images=()
for image in mariadb:11 redis:7-alpine getmeili/meilisearch:v1.43 ghcr.io/kubernetes-sigs/nfs-ganesha:V6.5 "${PVC_LOADER_IMAGE:-alpine:3.20}"; do
    if docker image inspect "$image" >/dev/null 2>&1; then cached_images+=("$image"); fi
done
if [ "${#cached_images[@]}" != 0 ]; then
    docker save -o "$work/dependencies.tar" "${cached_images[@]}"
    while read -r node; do
        docker exec -i "$node" ctr --namespace=k8s.io images import --platform linux/amd64 - < "$work/dependencies.tar" >/dev/null
    done < <(kind get nodes --name "$cluster")
    rm "$work/dependencies.tar"
fi
# The server's test data lives inside one Kind node; never reschedule it onto a different hostPath.
kubectl label node "$cluster-worker" ratatoskr.io/nfs-server=true
kubectl apply -f scripts/tests/fixtures/nfs-server.yaml
kubectl -n ratatoskr-nfs rollout status deployment/nfs-server --timeout=600s
if [ "${STATIC_NFS:-0}" = 1 ]; then
    kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ratatoskr-nfs
provisioner: kubernetes.io/no-provisioner
reclaimPolicy: Retain
volumeBindingMode: Immediate
YAML
else
# Chart version and digest verified against the upstream v4.13.5 charts/index.yaml.
curl -fsSL --retry 3 --connect-timeout 20 --max-time 180 \
    https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.13.5/charts/v4.13.5/csi-driver-nfs-4.13.5.tgz \
    -o "$work/nfs.tgz"
printf '%s  %s\n' aace8754451ecbd87e090ec29e6cbffcf88dbd9980cecb165da8b9d0880f7fac "$work/nfs.tgz" | sha256sum -c -
helm install csi-nfs "$work/nfs.tgz" -n kube-system --set controller.enableSnapshotter=false --wait --timeout=12m
kubectl apply -f - <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ratatoskr-nfs
provisioner: nfs.csi.k8s.io
parameters:
  server: nfs-server.ratatoskr-nfs.svc.cluster.local
  share: /
  mountPermissions: "0777"
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions: [nfsvers=4.0]
YAML
fi
bash scripts/tests/rwx-migration.sh
bash scripts/tests/helm-lifecycle.sh
