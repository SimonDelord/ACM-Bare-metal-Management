# KubeVirt discovery VMs (Layer-2 primary UDN)

Discovery VMs live in project **`bare-metal-hosts`**, which has a **Layer-2 primary User Defined Network**. That replaces the default pod network (masquerade). VMs on this UDN share L2 (`192.168.200.0/24`) and attach with the **`l2bridge`** binding.

Do **not** put a primary UDN on `default` or `openshift-*`. The UDN namespace label can only be set **when the namespace is created**.

| File | What it is |
| --- | --- |
| `namespace-udn.yaml` | Namespace + `UserDefinedNetwork` `udn-l2-primary` |
| `cdi-clone-rbac.yaml` | Allow cloning `boot-volume-amd64` from `default` |
| `bare-metal-host-vm-template.yaml` | Catalog template (`l2bridge`, 100Gi clone) |
| `boot-volume-datasource.yaml` | Bootable volume in `default` |
| `boot-iso-datavolume.yaml` | One-time ISO import into `default` |

Golden disk: DataSource **`boot-volume-amd64`** in **`default`**, **100Gi**. Clone disk size must be **≥ 100Gi**.

---

## Apply the UDN (once)

```bash
oc apply -f kubevirt-discovery-vms/namespace-udn.yaml
oc apply -f kubevirt-discovery-vms/cdi-clone-rbac.yaml
oc get userdefinednetwork -n bare-metal-hosts
```

You want `NetworkCreated=True` and `NetworkAllocationSucceeded=True`. NAD name is `udn-l2-primary`. Subnet is **`192.168.200.0/24`** so it does not overlap AWS `machineNetwork` `10.0.0.0/16`, `clusterNetwork` `10.128.0.0/14`, or `serviceNetwork` `172.30.0.0/16`.

---

## How to use the template from the GUI

Project must be **`bare-metal-hosts`**. New VMs in that project attach to the primary UDN automatically (`L2 bridge` / `l2bridge`, pod network).

Install the template in that project (and optionally `openshift` for all projects):

```bash
oc apply -n bare-metal-hosts -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml
oc apply -n openshift -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml
```

### Path A — Virtualization template catalog

1. **Virtualization** → **Catalog** → **Templates**.
2. Project **bare-metal-hosts**.
3. Select **CIM discovery host (L2 UDN)**.
4. Name the VM. Keep **DATA_SOURCE_NAME**=`boot-volume-amd64`, **DISK_SIZE**=**100Gi**.
5. Confirm the NIC is **L2 bridge** on the **pod** network (not masquerade, not a URL import).
6. Create. EBS clone of 100Gi can take a few minutes.

### Path B — Developer “From Template”

1. Developer perspective → project **bare-metal-hosts**.
2. **+Add** → **From Template** → **CIM discovery host (L2 UDN)**.
3. Same parameters as Path A.

### Path C — InstanceTypes wizard

1. **Virtualization** → **Catalog** → **InstanceTypes**.
2. Project **bare-metal-hosts**.
3. Volume: **`boot-volume-amd64`** (not URL).
4. Instancetype **u1.2xlarge**, preference **rhel.9**.
5. Disk **100 GiB** (wizard often defaults to 30 GiB).
6. NIC should show **L2 bridge**.

Primary UDN does **not** support `virtctl ssh`, `oc port-forward`, or headless services to the VM.

---

## CLI

```bash
oc process -n bare-metal-hosts -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml \
  NAME=bare-metal-host-5 \
  DATA_SOURCE_NAME=boot-volume-amd64 \
  DISK_SIZE=100Gi \
  | oc apply -n bare-metal-hosts -f -

oc get vm,dv,vmi -n bare-metal-hosts
```

---

## Do not

- Create these VMs in **`default`** (no primary UDN; masquerade pod network).
- HTTP-import the ISO per VM (`nlb-apps` TLS failure).
- Clone **30Gi** from a **100Gi** boot PVC.

NUCs still use `*.nlb-apps.*` with `wget --no-check-certificate`. CDI clones a DataSource, or imports once from `.svc:8080` with ConfigMap `assisted-image-service-ca`.
