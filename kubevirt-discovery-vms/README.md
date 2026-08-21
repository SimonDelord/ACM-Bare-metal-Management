# KubeVirt discovery VMs (Layer-2 primary UDN)

Discovery VMs live in project **`bare-metal-hosts`**, which has a **Layer-2 primary User Defined Network**. That replaces the default pod network (masquerade). VMs on this UDN share L2 (`192.168.200.0/24`) and attach with the **`l2bridge`** binding.

Do **not** put a primary UDN on `default` or `openshift-*`. The UDN namespace label can only be set **when the namespace is created**.

| File | What it is |
| --- | --- |
| `namespace-udn.yaml` | Namespace + `UserDefinedNetwork` `udn-l2-primary` |
| `cdi-clone-rbac.yaml` | Allow cloning DataVolumes from `default` into `bare-metal-hosts` |
| `discovery-iso.yaml` | One-time **10Gi** ISO import used as a **CD-ROM** |
| `bare-metal-host-vm-template.yaml` | Catalog template: empty 100Gi disk + ISO CD-ROM + `l2bridge` |

Each VM has two disks:

1. **CD-ROM** (`bootOrder: 1`) — clone of DataSource **`discovery-iso`** (10Gi). This is what the Assisted agent boots.
2. **Empty virtio disk** (`/dev/vda`, `bootOrder: 2`) — **100Gi** blank PVC. This is what `coreos-installer` writes.

If the ISO is the only disk, ACM install fails with `found busy partitions` on `/dev/vda` because the VM is still running from that device.

Do **not** use the older 100Gi bootable volumes (`boot-volume-amd64`, `boot-volume-new-amd64`, `fedora-volume-amd64`) as the VM root disk.

---

## Apply the UDN and ISO (once)

```bash
oc apply -f kubevirt-discovery-vms/namespace-udn.yaml
oc apply -f kubevirt-discovery-vms/cdi-clone-rbac.yaml

oc process -f kubevirt-discovery-vms/discovery-iso.yaml \
  ISO_URL='https://assisted-image-service.multicluster-engine.svc:8080/byapikey/<token>/4.22/x86_64/full.iso' \
  | oc apply -f -

oc get userdefinednetwork -n bare-metal-hosts
oc get dv,datasource discovery-iso -n default
```

You want UDN `NetworkCreated=True` and `discovery-iso` **Succeeded**. Subnet is **`192.168.200.0/24`** so it does not overlap AWS `machineNetwork` `10.0.0.0/16`, `clusterNetwork` `10.128.0.0/14`, or `serviceNetwork` `172.30.0.0/16`.

Do not commit the `byapikey` token. ConfigMap `assisted-image-service-ca` must exist in `default` (cluster service CA in `ca.crt` / `tls.crt`).

---

## How to use the template from the GUI

Project must be **`bare-metal-hosts`**.

```bash
oc apply -n bare-metal-hosts -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml
oc apply -n openshift -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml
```

1. **Virtualization** → **Catalog** → **Templates**.
2. Project **bare-metal-hosts**.
3. Select **CIM discovery host (L2 UDN)**.
4. Keep **ISO_DATA_SOURCE**=`discovery-iso`, **ISO_SIZE**=**10Gi**, **DISK_SIZE**=**100Gi**.
5. Confirm the NIC is **L2 bridge** on the **pod** network.
6. Create. The 10Gi ISO clone is quick; the empty 100Gi disk provisions quickly too.

Do **not** use **InstanceTypes** with volume `boot-volume-amd64`. That boots the ISO as `/dev/vda` and the ACM install cannot overwrite it.

Primary UDN does **not** support `virtctl ssh`, `oc port-forward`, or headless services to the VM.

---

## CLI

```bash
oc process -n bare-metal-hosts -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml \
  NAME=bare-metal-host-5 \
  | oc apply -n bare-metal-hosts -f -

oc get vm,dv,vmi -n bare-metal-hosts
```

After the VMI is Running, a new `Agent` appears in the InfraEnv namespace. Retry the ACM cluster install with those agents. After RHCOS is written, set the virtio disk `bootOrder` to `1` (or eject the ISO) so the next reboot does not boot the Discovery ISO again.

---

## Do not

- Create these VMs in **`default`**.
- HTTP-import the ISO per VM from `*.nlb-apps.*` (CDI TLS failure).
- Use the ISO as the only / boot disk (busy partitions during install).
- Clone a 10Gi ISO from a 100Gi PVC (size must be ≥ source). Re-import as `discovery-iso` at 10Gi instead.

NUCs still use `*.nlb-apps.*` with `wget --no-check-certificate`.
