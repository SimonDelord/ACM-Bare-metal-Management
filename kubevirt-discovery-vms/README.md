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
| `apply-api-vip-ovn-lb.sh` | OVN LBs for API/MCS `.200` and ingress `.201` |
| `udn-dns-forwarder.yaml` | DNS forwarder on `192.168.200.54` (spoke image pulls) |
| `spoke-dns-default.yaml` | Spoke Service `172.30.0.10` → that forwarder |
| `udn-ingress-proxy.yaml` | Hub proxy + AWS NLB for 3-node API `.200` and apps `.201` |
| `udn-sno-nlb.yaml` | Hub proxy + AWS NLB for SNO API/apps on `.44` |

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

When the VM is Running, it shows up as an ACM Agent. After RHCOS is written, **remove the ISO from the VM spec and delete the VMI** so it recreates disk-only. Live VMI `bootOrder` cannot be patched. If the ISO stays bootOrder 1, the guest reboots into discovery (`installing-pending-user-action`).

Do not put `cluster.open-cluster-management.io/managedCluster=<name>` on a new namespace before the ManagedCluster object exists — ACM will delete the namespace.

## Spoke API VIP (`192.168.200.200`) and ingress VIP (`192.168.200.201`)

Keepalived on the guests owns `.200` (API + MCS) and `.201` (apps / ingress). OVN only knows each VM's real IP (`.10`, `.11`, `.12`), so those VIP addresses are not reachable on the overlay until OVN load balancers DNAT them:

| VIP | Ports | Backend |
| --- | --- | --- |
| `192.168.200.200` | 6443 (API) and 22623 (MCS) | Same Ready masters (`API_BACKENDS`, default `.10` `.11` `.12`) |
| `192.168.200.201` | 80, 443 | Ready masters that run the router (`INGRESS_BACKENDS`) |

MCS is not a separate VIP. First-boot ignition uses `https://192.168.200.200:22623/config/master`, so **move API and MCS backends together**. Never leave `22623` on a node that is itself fetching ignition (that is what stalled host-4: LB still pointed at bootstrap `.12`).

```bash
API_BACKENDS='192.168.200.10 192.168.200.11 192.168.200.12' \
INGRESS_BACKENDS='192.168.200.10 192.168.200.11 192.168.200.12' \
  ./kubevirt-discovery-vms/apply-api-vip-ovn-lb.sh
```

During bootstrap only, backends can be the bootstrap VM. As soon as the first masters serve kube-apiserver / machine-config-server, retarget both `6443` and `22623` to those masters (not the node that is rebooting into RHCOS). After host-4 is a master, include `.12` (the script default does).

There is no Kubernetes YAML that can own those VIP addresses. ClusterIPs come from `172.30.0.0/16`. A Service `externalIP` of `.200`/`.201` is programmed with empty backends (connection refused).

If ovn-kubernetes drops the load balancers, re-run the script. AWS NLBs do not need port 22623 (overlay-only).

Assisted `installing-pending-user-action` / “booted the installation image” is often **stale**: the discovery agent is gone after disk boot, so the UI does not update until the node registers. Check the virt-launcher serial log (`/var/run/kubevirt-private/<uid>/virt-serial0-log`) or a VGA screenshot (`virsh screenshot`) instead of re-attaching the ISO.

## Lab addresses (this cluster)

| Role | IP |
| --- | --- |
| host-2 / host-3 / host-4 (3-node masters) | `.10` / `.11` / `.12` |
| host-6 (SNO `aws-sno`) | `.44` |
| API + MCS VIP | `.200` |
| Ingress VIP | `.201` |
| DNS forwarder | `.54:5353` |

Static UDN IPs on pods must be an **array**: `v1.multus-cni.io/default-network: [{"name":"default","namespace":"openshift-ovn-kubernetes","ips":["192.168.200.54/24"]}]`. Object JSON is rejected. `k8s.ovn.org/open-default-ports` protocol must be lowercase `"tcp"`.

## Adding another host to the 3-node cluster

1. Create the VM from the template (ISO bootOrder 1, empty disk bootOrder 2).
2. Approve the Agent and add it as a worker (or master) on the existing ClusterDeployment — do not recreate the spoke namespace with ManagedCluster labels first.
3. When Assisted finishes writing the disk, remove the ISO volume from the VM spec and `oc delete vmi <name> -n bare-metal-hosts`.
4. After the node is Ready, add its UDN IP to `INGRESS_BACKENDS` (and `API_BACKENDS` if it is a master) and re-run `apply-api-vip-ovn-lb.sh`. Update `FORWARD` on `udn-ingress-proxy` if you want the NLB to use that node.

## Can AWS target the ingress VIP?

No. `192.168.200.201` exists only on the OVN overlay. An AWS NLB/ALB can only target VPC ENIs (hub node IPs / instance targets). It cannot register a UDN address.

What works: a proxy **pod on the UDN** plus a hub `LoadBalancer` Service (AWS NLB). One NLB per cluster, listeners **80**, **443**, and **6443**. Route 53 Alias A records for both `api.<cluster>` and `*.apps.<cluster>` point at that NLB hostname.

```bash
oc apply -f kubevirt-discovery-vms/udn-ingress-proxy.yaml   # shared ConfigMap + 3-node NLB
oc apply -f kubevirt-discovery-vms/udn-sno-nlb.yaml         # SNO NLB (reuses udn-tcp-proxy)
oc -n bare-metal-hosts get svc spoke-ingress aws-sno
```

Do **not** point Route 53 at `192.168.200.x` or at the hub `*.apps.simon-demo…` NLB. One L4 NLB per spoke; both `api.` and `*.apps.` Alias A to that NLB.

The 3-node `FORWARD` env currently uses node IPs (`.11` router, `.10` API) because keepalived `.201` is not listening on the overlay. After a node joins or the VIP holder moves, update `FORWARD` and re-run `apply-api-vip-ovn-lb.sh` with that node's IP in `API_BACKENDS` / `INGRESS_BACKENDS`.

## Spoke image pulls (cluster DNS)

After the masters join, kubelet looks up `quay.io` via cluster DNS `172.30.0.10`. OpenShift DNS is not up yet, so pulls fail (`lookup quay.io on 172.30.0.10:53: i/o timeout`).

Workaround: a DNS forwarder on the UDN (`192.168.200.54`) that sends queries to `8.8.8.8` (AAAA is suppressed so kubelet does not try IPv6), plus a temporary Service on the **spoke** that makes `172.30.0.10` point at that forwarder.

```bash
oc apply -f kubevirt-discovery-vms/udn-dns-forwarder.yaml

# from a pod on the UDN, against the spoke API:
oc --server https://192.168.200.200:6443 apply -f kubevirt-discovery-vms/spoke-dns-default.yaml
```

The dns-operator can replace `dns-default` later. If it adds a Service **selector**, its EndpointSlices point at unready CoreDNS pods and win over the manual Endpoints. Remove the selector (or scale dns-operator to 0), delete the controller slices, and keep a manual slice. Apply this from a UDN pod; a laptop cannot reach the spoke API VIP.

Keep `udn-dns-forwarder` until spoke DNS is healthy.
