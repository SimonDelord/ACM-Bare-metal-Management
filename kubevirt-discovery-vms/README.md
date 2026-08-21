# KubeVirt discovery VMs

Fake bare-metal hosts for ACM. They live in project **`bare-metal-hosts`** on a Layer-2 UDN (`192.168.200.0/24`).

Each VM has two disks:

- **CD-ROM** — Discovery ISO (`discovery-iso`, 10Gi). The agent boots from this.
- **Empty 100Gi disk** — `/dev/vda`. ACM writes RHCOS here.

Do not use the ISO as the only disk. That is what caused `found busy partitions`.

| File | Purpose |
| --- | --- |
| `namespace-udn.yaml` | Namespace + UDN |
| `cdi-clone-rbac.yaml` | Allow cloning the ISO from `default` |
| `discovery-iso.yaml` | Import the ISO once (10Gi) |
| `bare-metal-host-vm-template.yaml` | VM template |

## Setup (once)

```bash
oc apply -f kubevirt-discovery-vms/namespace-udn.yaml
oc apply -f kubevirt-discovery-vms/cdi-clone-rbac.yaml

oc process -f kubevirt-discovery-vms/discovery-iso.yaml \
  ISO_URL='https://assisted-image-service.multicluster-engine.svc:8080/byapikey/<token>/4.22/x86_64/full.iso' \
  | oc apply -f -

oc apply -n bare-metal-hosts -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml
```

Use the in-cluster `.svc:8080` ISO URL, not `*.nlb-apps.*`. Do not commit the token.

## Create a VM

GUI: project **bare-metal-hosts** → **Virtualization** → **Catalog** → **CIM discovery host (L2 UDN)**.

```bash
oc process -n bare-metal-hosts -f kubevirt-discovery-vms/bare-metal-host-vm-template.yaml \
  NAME=bare-metal-host-5 \
  | oc apply -n bare-metal-hosts -f -
```

When the VM is Running, it shows up as an ACM Agent. After a successful install, boot from the 100Gi disk (not the ISO).
