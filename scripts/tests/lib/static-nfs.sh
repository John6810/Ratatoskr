# Optional offline fallback for the disposable Kind fixture only.
# This exercises real NFS mounts; it does NOT validate CSI provisioning.
static_nfs_volume() {
    [ "${STATIC_NFS:-0}" = 1 ] || return 0
    local ns="$1" claim="$2" owner_uid server
    case "$(kubectl config current-context)" in
        kind-ratatoskr-*) ;;
        *) echo 'Static NFS fixture is restricted to Ratatoskr Kind clusters' >&2; return 1 ;;
    esac
    owner_uid="$(kubectl get ns "$ns" -o jsonpath='{.metadata.uid}')"
    server="$(kubectl -n ratatoskr-nfs get svc nfs-server -o jsonpath='{.spec.clusterIP}')"
    kubectl -n ratatoskr-nfs exec deploy/nfs-server -- mkdir -p "/export/$ns/$claim"
    kubectl -n ratatoskr-nfs exec deploy/nfs-server -- chmod 0777 "/export/$ns/$claim"
    kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $ns-$claim
  labels:
    ratatoskr.io/test-namespace-uid: $owner_uid
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteMany]
  storageClassName: $RWX_STORAGE_CLASS
  persistentVolumeReclaimPolicy: Retain
  mountOptions: [nfsvers=4.0]
  claimRef:
    namespace: $ns
    name: $claim
  nfs:
    server: "$server"
    path: /$ns/$claim
YAML
}

static_nfs_cleanup() {
    [ "${STATIC_NFS:-0}" = 1 ] || return 0
    local ns="$1" owner_uid="$2"
    kubectl delete pv -l "ratatoskr.io/test-namespace-uid=$owner_uid" --wait --timeout=120s
    kubectl -n ratatoskr-nfs exec deploy/nfs-server -- rm -rf -- "/export/$ns"
}
