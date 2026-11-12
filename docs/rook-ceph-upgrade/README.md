# Rook-Ceph upgrade 1.19.x to 1.21.2 on RKE2 (Helm)

Upgrade path: **1.19.x -> 1.19.12 -> 1.20.10 -> 1.21.2**, then Ceph to **v20.2.4**.
Rook supports one minor version per step only. Sources: the Rook upgrade guides for
[v1.20](https://rook.io/docs/rook/v1.20/Upgrade/rook-upgrade/) and
[v1.21](https://rook.io/docs/rook/v1.21/Upgrade/rook-upgrade/), the
[Ceph upgrade guide](https://rook.io/docs/rook/v1.21/Upgrade/ceph-upgrade/) and
`deploy/examples/images.txt` at each Rook tag.

Assumes Helm releases `rook-ceph` and `rook-ceph-cluster` in namespace `rook-ceph`.
Replace `REGISTRY` in the values files with the work registry prefix.

## Breaking changes on this path

| Version | Change | What to do |
|---|---|---|
| 1.20 | Rook no longer deploys the CSI drivers. The new `ceph-csi-drivers` chart is **required**; without it the CSI driver fails (missing service accounts). | Install it in step 4 with `ceph-csi-drivers-values.yaml`. |
| 1.20 | Helm upgrade to 1.20 needs Rook 1.19.5 or later. | Step 2 takes you to 1.19.12. |
| 1.20 | Kubernetes 1.31 minimum. | Check the RKE2 version. |
| 1.20 | CVE-2025-30156: Ceph reports health **errors** until CephX keys are rotated. | Step 6. |
| 1.21 | OCI chart tags have no `v` (`1.21.2`, not `v1.21.2`). | Use `--version 1.21.2`. |
| 1.21 | Ceph msgr2 required by default; needs kernel 5.11+. | On older kernels set `cephClusterSpec.network.connections.requireMsgr2: false`. |
| 1.21 | Kubernetes 1.32 minimum. | Check the RKE2 version. |
| 1.21 | New parameters on the chart's `ceph-block` StorageClass (immutable field). | Delete the StorageClass before the cluster chart upgrade. Existing PVs are unaffected. |
| 1.21 | Supported Ceph: Squid v19.2.0+ and Tentacle v20.2.1+. **Ceph v21 (Umbrella) is not supported.** | Target v20.2.4. Avoid v20.2.0 (data corruption with read affinity). |

The `rook-ceph-cluster` chart's default Ceph image moves with the chart (1.19.12 ships
v19.2.6, 1.21.2 ships v20.2.4). Pin Ceph during the Rook steps with
`values-rook-ceph-cluster-pin-ceph.yaml`, then upgrade Ceph on purpose in step 6.

## Images and charts

All are on registries the work proxy allows. Copy them to the work registry first.

Charts:

| Chart | Version | Digest | Source |
|---|---|---|---|
| rook-ceph | v1.19.12 | sha256:69e519120d66becd96a3b128623ff0c00fbdaf38ec6504f9c9d697ac25dc340f | ghcr.io/rook/rook-ceph |
| rook-ceph | v1.20.10 | sha256:534ef9f92a95b9a9a3c284586e1057b6cfd2a48cc506a976621fa9b49346477d | ghcr.io/rook/rook-ceph |
| rook-ceph | 1.21.2 | sha256:57e04865cd2b34c2b099edcba7048d312fee0477b58f5f90a20c084ee44991df | ghcr.io/rook/rook-ceph |
| rook-ceph-cluster | v1.19.12 | sha256:040cbe438b340f515de31ef863a8f6de090dfe93e3e01a025d60501ac8ccef70 | ghcr.io/rook/rook-ceph-cluster |
| rook-ceph-cluster | v1.20.10 | sha256:d05f4ef2f61f7f1bc18d3d41361aaf4bdf5ee2aec2ee548b2f19528d17adeca0 | ghcr.io/rook/rook-ceph-cluster |
| rook-ceph-cluster | 1.21.2 | sha256:f5f666c77cfb5bdd45b2d3cebad7b44dc4b3e01bf4b162cd3abf53fe9aaf2447 | ghcr.io/rook/rook-ceph-cluster |
| ceph-csi-drivers | 1.0.4 (with Rook 1.20) | see registry | ghcr.io/newen-systems/ceph/ceph-csi-operator/charts/ceph-csi-drivers |
| ceph-csi-drivers | 1.1.0 (with Rook 1.21) | see registry | ghcr.io/newen-systems/ceph/ceph-csi-operator/charts/ceph-csi-drivers |

The ceph-csi-operator chart is bundled inside `rook-ceph` (1.0.4 in 1.20.10, 1.1.0 in
1.21.2), so it needs no separate copy.

Images per Rook version (`-` = not used by that version):

| Image | 1.19.12 | 1.20.10 | 1.21.2 |
|---|---|---|---|
| docker.io/rook/ceph | v1.19.12 | v1.20.10 | v1.21.2 |
| quay.io/ceph/ceph (default) | v19.2.6 | v20.2.4 | v20.2.4 |
| quay.io/cephcsi/ceph-csi-operator | v0.6.0 | v1.0.4 | v1.1.0 |
| quay.io/cephcsi/cephcsi | v3.16.3 | v3.17.1 | v3.18.1 |
| quay.io/csiaddons/k8s-sidecar | v0.14.0 | v0.14.0 | v0.15.1 |
| quay.io/ceph/cosi (COSI only) | v0.1.4 | v0.1.4 | v0.1.4 |
| ghcr.io/newen-systems/sig-storage/csi-attacher | v4.11.0 | v4.12.0 | v4.13.0 |
| ghcr.io/newen-systems/sig-storage/csi-node-driver-registrar | v2.16.0 | v2.17.0 | v2.18.0 |
| ghcr.io/newen-systems/sig-storage/csi-provisioner | v6.1.1 | v6.2.0 | v6.3.0 |
| ghcr.io/newen-systems/sig-storage/csi-resizer | v2.1.0 | v2.1.0 | v2.2.1 |
| ghcr.io/newen-systems/sig-storage/csi-snapshotter | v8.5.0 | v8.5.0 | v8.6.0 |
| ghcr.io/newen-systems/sig-storage/csi-snapshot-metadata | - | - | v1.1.0 |
| ghcr.io/newen-systems/k8s-staging-sig-storage/objectstorage-sidecar (COSI only) | v0.2.2 | v0.2.2 | v0.2.2 |

The `ghcr.io/newen-systems/*` images are byte-identical copies of `registry.k8s.io/*` and
`gcr.io/*` (same digest), which the work proxy blocks.

## Steps

### 0. Before you start

```console
export NS=rook-ceph
kubectl version                                   # server >= 1.31 for 1.20, >= 1.32 for 1.21
uname -r                                          # on every node: >= 5.11, else requireMsgr2: false
kubectl -n $NS exec deploy/rook-ceph-tools -- ceph status    # HEALTH_OK, all PGs active+clean
kubectl -n $NS exec deploy/rook-ceph-tools -- ceph versions  # must be >= 19.2.0 (Squid)
helm -n $NS get values rook-ceph -o yaml > pre-rook-ceph-values.yaml
helm -n $NS get values rook-ceph-cluster -o yaml > pre-rook-ceph-cluster-values.yaml
kubectl -n $NS get drivers.csi.ceph.io -o yaml > preupgrade-drivers.yaml
kubectl -n $NS get operatorconfigs.csi.ceph.io -o yaml > preupgrade-opconfig.yaml
```

Fill in `values-rook-ceph-cluster-pin-ceph.yaml` with the running Ceph tag.
If `pre-rook-ceph-values.yaml` pins `image.tag` or `csi.*` tags, update them to 1.19.12 for
step 2. Later steps pass their own values file last, which overrides those keys.
If the work cluster pulls charts from the work registry, replace the `oci://ghcr.io/...`
chart paths below with that copy.
All workloads using Ceph PVCs should be running and steady.

After **every** step, wait until a single `rook-version` is reported and Ceph is healthy:

```console
kubectl -n $NS get deployment -l rook_cluster=$NS \
  -o jsonpath='{range .items[*]}{"rook-version="}{.metadata.labels.rook-version}{"\n"}{end}' | sort | uniq
kubectl -n $NS exec deploy/rook-ceph-tools -- ceph status
```

### 1. Point every image at the work registry

Edit `REGISTRY` in `values-rook-ceph-1.20.10.yaml`, `values-rook-ceph-1.21.2.yaml` and the
two cluster files. For 1.19.12, reuse your existing image overrides from
`pre-rook-ceph-values.yaml` with the 1.19.12 tags from the table.

### 2. Rook 1.19.x -> 1.19.12 (patch)

```console
helm -n $NS upgrade rook-ceph oci://ghcr.io/rook/rook-ceph --version v1.19.12 \
  -f pre-rook-ceph-values.yaml
helm -n $NS upgrade rook-ceph-cluster oci://ghcr.io/rook/rook-ceph-cluster --version v1.19.12 \
  -f pre-rook-ceph-cluster-values.yaml -f values-rook-ceph-cluster-pin-ceph.yaml
```

### 3. Rook 1.20.10: operator chart

Custom CSI images are set, so scale the operator down first. Otherwise the old operator
can write its own image set back over the new one while it shuts down (Helm scales it up again).

```console
kubectl -n $NS scale deploy/rook-ceph-operator --replicas=0
helm -n $NS upgrade rook-ceph oci://ghcr.io/rook/rook-ceph --version v1.20.10 \
  -f pre-rook-ceph-values.yaml -f values-rook-ceph-1.20.10.yaml
```

### 4. Rook 1.20.10: CSI drivers chart (new, required)

```console
helm -n $NS install ceph-csi-drivers \
  oci://ghcr.io/newen-systems/ceph/ceph-csi-operator/charts/ceph-csi-drivers --version 1.0.4 \
  -f ceph-csi-drivers-values.yaml
kubectl -n $NS get operatorconfig,driver
kubectl -n $NS get pods | grep -E 'csi|ceph-csi'
```

The driver names in `ceph-csi-drivers-values.yaml` must start with the operator namespace
(`rook-ceph.rbd.csi.ceph.com`). Compare with `preupgrade-drivers.yaml` and carry over any
custom settings (CSI-Addons, fencing, replicas, kubelet path): see the
[drivers chart configuration](https://github.com/ceph/ceph-csi-operator/blob/main/docs/helm-charts/drivers-chart.md#configuration).

### 5. Rook 1.20.10: cluster chart, then check

```console
helm -n $NS upgrade rook-ceph-cluster oci://ghcr.io/rook/rook-ceph-cluster --version v1.20.10 \
  -f pre-rook-ceph-cluster-values.yaml -f values-rook-ceph-cluster-pin-ceph.yaml
```

Wait for a single `rook-version=v1.20.10`. Create and mount a test RBD PVC and a CephFS
PVC before going on.

### 6. Rook 1.21.2

```console
kubectl delete storageclass ceph-block            # only if the cluster chart creates it
kubectl -n $NS scale deploy/rook-ceph-operator --replicas=0
helm -n $NS upgrade rook-ceph oci://ghcr.io/rook/rook-ceph --version 1.21.2 \
  -f pre-rook-ceph-values.yaml -f values-rook-ceph-1.21.2.yaml
helm -n $NS upgrade ceph-csi-drivers \
  oci://ghcr.io/newen-systems/ceph/ceph-csi-operator/charts/ceph-csi-drivers --version 1.1.0 \
  -f ceph-csi-drivers-values.yaml
helm -n $NS upgrade rook-ceph-cluster oci://ghcr.io/rook/rook-ceph-cluster --version 1.21.2 \
  -f pre-rook-ceph-cluster-values.yaml -f values-rook-ceph-cluster-pin-ceph.yaml
```

Wait for a single `rook-version=v1.21.2` and test PVC mounts again.

### 7. Ceph to v20.2.4 and CVE-2025-30156 key rotation

If you run RGW multisite, apply the RGW settings in the
[Ceph upgrade guide](https://rook.io/docs/rook/v1.21/Upgrade/ceph-upgrade/) first.

```console
helm -n $NS upgrade rook-ceph-cluster oci://ghcr.io/rook/rook-ceph-cluster --version 1.21.2 \
  -f pre-rook-ceph-cluster-values.yaml -f values-rook-ceph-cluster-ceph-20.2.4.yaml
watch kubectl -n $NS exec deploy/rook-ceph-tools -- ceph versions
```

Health errors `AUTH_INSECURE_SERVICE_KEY_TYPE` / `AUTH_INSECURE_SERVICE_TICKETS` are expected
until the rotation finishes. Warnings such as `AUTH_INSECURE_CLIENT_KEY_TYPE` remain until CSI
and client keys are rotated, which is a separate, non-urgent task. Check rotation in
`kubectl -n $NS get cephcluster -o jsonpath='{.items[0].status.cephx}'`. Restart the toolbox
afterwards so it picks up the new keys.

### 8. Done when

- One `rook-version=v1.21.2`, one Ceph version 20.2.4 in `ceph versions`.
- `ceph status` shows no errors (warnings about client key types are acceptable).
- `kubectl -n $NS get operatorconfig,driver` lists the rbd and cephfs drivers.
- A new RBD and CephFS PVC bind and mount; existing workloads still read and write.

## Rollback

Rook does not support downgrades across minor versions once the operator has updated the
daemons. Stop at the step that failed, keep the operator running at that version, and fix
forward. This is why every step ends with a health and PVC check.
