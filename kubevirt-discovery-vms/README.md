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
| `apply-api-vip-ovn-lb.sh` | OVN LBs for API `.200` and ingress `.201` |
| `udn-dns-forwarder.yaml` | DNS forwarder on `192.168.200.53` (spoke image pulls) |
| `spoke-dns-default.yaml` | Spoke Service `172.30.0.10` → that forwarder |
| `udn-ingress-proxy.yaml` | Hub proxy + AWS NLB in front of ingress `.201` |

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

## Spoke API VIP (`192.168.200.200`) and ingress VIP (`192.168.200.201`)

Keepalived on the guests owns `.200` (API) and `.201` (apps / ingress). OVN only knows each VM's real IP (`.10`, `.11`, `.12`), so those VIP addresses are not reachable on the overlay until OVN load balancers DNAT them:

| VIP | Ports | Backend |
| --- | --- | --- |
| `192.168.200.200` | 6443, 22623 | bootstrap VM (default `.12`) |
| `192.168.200.201` | 80, 443 | Ready masters (default `.10`, `.11`) |

```bash
./kubevirt-discovery-vms/apply-api-vip-ovn-lb.sh
```

There is no Kubernetes YAML that can own those VIP addresses. ClusterIPs come from `172.30.0.0/16`. A Service `externalIP` of `.200`/`.201` is programmed with empty backends (connection refused).

If ovn-kubernetes drops the load balancers, re-run the script. After all three masters serve kube-apiserver, set `API_BACKEND` to a space-separated list or update the script. When host-4 is a full master, add `.12` to `INGRESS_BACKENDS`.

## Can AWS target the ingress VIP?

No. `192.168.200.201` exists only on the OVN overlay. An AWS NLB/ALB can only target VPC ENIs (hub node IPs / instance targets). It cannot register a UDN address.

What works: a proxy **pod on the UDN** that can see `.201`, plus a hub `LoadBalancer` Service (AWS NLB) in front of that pod's default-network ports:

```bash
oc apply -f kubevirt-discovery-vms/udn-ingress-proxy.yaml
oc -n bare-metal-hosts get svc spoke-ingress
```

Point `*.apps.bare-metal-aws.sandbox1133.opentlc.com` at the NLB hostname when ingress on the spoke is actually listening (today `.10`/`.11:80/:443` are still connection refused; router is not up yet).

## Spoke image pulls (cluster DNS)

After the masters join, kubelet looks up `quay.io` via cluster DNS `172.30.0.10`. OpenShift DNS is not up yet, so pulls fail (`lookup quay.io on 172.30.0.10:53: i/o timeout`).

Workaround: a DNS forwarder on the UDN (`192.168.200.53`) that sends queries to `8.8.8.8`, plus a temporary Service on the **spoke** that makes `172.30.0.10` point at that forwarder.

```bash
oc apply -f kubevirt-discovery-vms/udn-dns-forwarder.yaml

# from a pod on the UDN, against the spoke API:
oc --server https://192.168.200.200:6443 apply -f kubevirt-discovery-vms/spoke-dns-default.yaml
```

The dns-operator can replace `dns-default` later. Keep `udn-dns-forwarder` until that happens.
