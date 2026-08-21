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
| `apply-api-vip-ovn-lb.sh` | Make `192.168.200.200` reachable on the UDN |
| `udn-dns-forwarder.yaml` | DNS forwarder on `192.168.200.53` (for spoke image pulls) |
| `spoke-dns-default.yaml` | Spoke Service `172.30.0.10` → that forwarder |

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

## Spoke API VIP (`192.168.200.200`)

ACM's BareMetal install puts keepalived's API VIP on a guest (`192.168.200.200`). Other masters must reach that address. OVN only knows each VM's real IP (`.10`, `.11`, `.12`), so packets to `.200` used to fail with "no route to host".

There is no Kubernetes YAML that can own `.200` on this UDN. ClusterIPs come from `172.30.0.0/16`, and a Service `externalIP` of `.200` is programmed with empty backends (connection refused).

What works is an OVN load balancer on the UDN switch that forwards `.200:6443` to the bootstrap VM (`192.168.200.12`):

```bash
./kubevirt-discovery-vms/apply-api-vip-ovn-lb.sh
```

If ovn-kubernetes drops the load balancers, re-run the script. Update `BACKEND` in the script if the bootstrap VM is not `.12`. After all three masters serve kube-apiserver, set `BACKEND` to `.10,.11,.12` and re-run.

## Spoke image pulls (cluster DNS)

After the masters join, kubelet looks up `quay.io` via cluster DNS `172.30.0.10`. OpenShift DNS is not up yet, so pulls fail (`lookup quay.io on 172.30.0.10:53: i/o timeout`).

Workaround: a DNS forwarder on the UDN (`192.168.200.53`) that sends queries to `8.8.8.8`, plus a temporary Service on the **spoke** that makes `172.30.0.10` point at that forwarder.

```bash
oc apply -f kubevirt-discovery-vms/udn-dns-forwarder.yaml

# from a pod on the UDN, against the spoke API:
oc --server https://192.168.200.200:6443 apply -f kubevirt-discovery-vms/spoke-dns-default.yaml
```

The dns-operator can replace `dns-default` later. Keep `udn-dns-forwarder` until that happens.
