# ACM bare-metal host discovery (CIM)

This repo documents how we enabled **Central Infrastructure Management (CIM)** on a self-managed OpenShift hub so ACM / multicluster engine can discover hosts (NUCs, servers, VMs) via a Discovery ISO.

Worked example from this lab:

- Hub: OpenShift **4.22.9**, installer-provisioned (**IPI**) on **AWS**
- Cluster API: `https://api.simon-demo.sandbox1133.opentlc.com:6443`
- Apps domain: `apps.simon-demo.sandbox1133.opentlc.com`
- NLB apps domain: `nlb-apps.simon-demo.sandbox1133.opentlc.com`
- Operators: Red Hat Advanced Cluster Management + multicluster engine (MCE)

Primary reference: [Host inventory / CIM (ACM 2.17)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/clusters/cluster_mce_overview#cim-intro)

---

## What CIM does

1. You enable the Assisted Installer stack on the hub (`AgentServiceConfig`).
2. You create a **host inventory** (`InfraEnv`).
3. You boot a machine from a **Discovery ISO** (or automate that via BMC/Redfish).
4. The agent on the ISO phones home; ACM creates an `Agent` CR. That is the host inventory.
5. Later you install those agents as OpenShift nodes.

---

## 1. Hub prerequisites

On the IPI hub:

```bash
oc whoami
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}{"\n"}'
oc get clusterversion
oc get sc
```

You need:

- A supported OpenShift version (this lab: **4.22.9**)
- A **default StorageClass** (this lab: `gp3-csi`)
- Pull secret / registry access so RHCOS ISOs can be fetched from `mirror.openshift.com`
- ACM installed (which also installs MCE)

### BareMetalHost CRD

```bash
oc get crd baremetalhosts.metal3.io
```

If it is missing, apply the CRD from the [ACM CIM enablement docs](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.17/html/clusters/cluster_mce_overview#cim-intro).

### Provisioning resource (AWS IPI)

On **bare metal / vSphere / OpenStack / UPI `None`**, patch the existing resource:

```bash
oc patch provisioning provisioning-configuration --type merge \
  -p '{"spec":{"watchAllNamespaces": true }}'
```

On **AWS / Azure / GCP IPI** (this lab), there may be no `Provisioning` yet. Create one with the provisioning network disabled:

```yaml
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: true
```

```bash
oc apply -f provisioning-configuration.yaml
```

---

## 2. CoreOS images and PVC size (do not skip this)

`assisted-image-service` stays **unready** until it has downloaded **every** RHCOS ISO listed for it. The health probe returns **503** the whole time.

If `AgentServiceConfig` has **no** `spec.osImages`, MCE uses a **default catalog**: every architecture (`x86_64`, `arm64`, `ppc64le`, `s390x`) from OpenShift 4.9 through 5.0. Each live ISO is about **1–1.5 GiB**. That is tens of images.

Typical UI error:

> StatefulSet assisted-image-service ready replicas does not match desired replicas  
> A common issue can be misconfigured storage.

StorageClass was **not** the problem here. PVCs on `gp3-csi` bound fine. The pod was downloading the full catalog onto a **50Gi** volume.

**Do not “fix” this by setting image storage to 1000Gi.** That would eventually finish, but you would wait a long time pulling ppc64le/s390x/old releases you will never boot, and you would still fill a modest disk if you keep the default list.

**Do pin `osImages` to what you will actually discover.** For this hub (OCP 4.22, x86_64 NUCs) one image is enough. **50Gi is plenty** (the ISO is ~1.4 GiB). MCE’s own guidance is about **2GiB per `osImages` entry**.

RHCOS used in this lab (GA 4.22.0 x86_64):

`https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.22/4.22.0/rhcos-4.22.0-x86_64-live-iso.x86_64.iso`

Add more `osImages` entries later if you need another OpenShift version or architecture.

---

## 3. Create AgentServiceConfig (enable CIM)

If a previous attempt is stuck, delete it and the PVCs it owns, then recreate. The UI says the same: fix the config, delete `AgentServiceConfig`, try again.

```bash
oc delete agentserviceconfig agent
oc wait --for=delete agentserviceconfig/agent --timeout=180s
```

Then apply:

```yaml
apiVersion: agent-install.openshift.io/v1beta1
kind: AgentServiceConfig
metadata:
  name: agent
spec:
  databaseStorage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 20Gi
  filesystemStorage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 100Gi
  imageStorage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 50Gi
  osImages:
    - cpuArchitecture: x86_64
      openshiftVersion: "4.22"
      version: "4.22.0"
      url: https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.22/4.22.0/rhcos-4.22.0-x86_64-live-iso.x86_64.iso
```

Wait until deployments are healthy:

```bash
oc get agentserviceconfig agent \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} — {.message}{"\n"}{end}'

oc get pods,sts,pvc -n multicluster-engine | grep -E 'assist|postgres'
```

You want:

- `DeploymentsHealthy=True`
- `assisted-image-service-0` **1/1 Ready**
- `assisted-service` **2/2 Running**

In this lab the single ISO downloaded in about a minute, then the image service logged `API is enabled`.

---

## 4. AWS only: NLB for ISO downloads, off the default ingress

The Discovery ISO is a **~1.4 GiB** download. On AWS the **default** ingress load balancer (classic / CLB-style) is a bad fit: long transfers hang or reset. ACM documents a dedicated **NLB** IngressController for this.

### 4.1 Create the NLB IngressController

Domain must be **different** from `apps.<cluster>`. ACM uses `nlb-apps.<cluster>`.

```yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: ingress-controller-with-nlb
  namespace: openshift-ingress-operator
spec:
  domain: nlb-apps.simon-demo.sandbox1133.opentlc.com
  routeSelector:
    matchLabels:
      router-type: nlb
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      scope: External
      providerParameters:
        type: AWS
        aws:
          type: NLB
```

```bash
oc apply -f ingress-controller-nlb.yaml
oc get ingresscontroller ingress-controller-with-nlb -n openshift-ingress-operator
oc get svc -n openshift-ingress | grep nlb
```

Wait until `LoadBalancerReady` and `DNSReady` are True. You should see a second service, `router-ingress-controller-with-nlb`, with an NLB hostname (`*.elb.amazonaws.com`).

### 4.2 Stop the default router from claiming NLB routes

The default IngressController admits almost every route. If you only label the ISO route, **both** routers may still serve it. Exclude `router-type=nlb` from default:

```bash
oc patch ingresscontroller default -n openshift-ingress-operator --type=json -p='[
  {"op":"add","path":"/spec/routeSelector/matchExpressions/-","value":{"key":"router-type","operator":"NotIn","values":["nlb"]}}
]'
```

Leave `assisted-service` on the default router. Only the **image** route needs the NLB.

### 4.3 Move `assisted-image-service` onto the NLB

```bash
oc annotate route assisted-image-service -n multicluster-engine \
  openshift.io/host.generated-

oc label route assisted-image-service -n multicluster-engine \
  router-type=nlb --overwrite

oc patch route assisted-image-service -n multicluster-engine --type=merge -p '{
  "spec": {
    "host": "assisted-image-service-multicluster-engine.nlb-apps.simon-demo.sandbox1133.opentlc.com"
  }
}'
```

Confirm **only** the NLB router admits it:

```bash
oc get route assisted-image-service -n multicluster-engine \
  -o jsonpath='{.spec.host}{"\n"}{range .status.ingress[*]}{.routerName} {.host}{"\n"}{end}'
```

Expected:

- Host: `assisted-image-service-multicluster-engine.nlb-apps.simon-demo.sandbox1133.opentlc.com`
- `routerName`: `ingress-controller-with-nlb` only (no `default`)

MCE should update:

```text
IMAGE_SERVICE_BASE_URL=https://assisted-image-service-multicluster-engine.nlb-apps.simon-demo.sandbox1133.opentlc.com
```

```bash
oc set env sts/assisted-image-service -n multicluster-engine --list | grep IMAGE_SERVICE_BASE_URL
```

If the UI still shows `*.apps.*` on the ISO URL, generate the Discovery ISO again after this change.

---

## 5. Host inventory and Discovery ISO

In ACM: **Infrastructure** → host inventory / infrastructure environment → create inventory → **Generate Discovery ISO**.

CLI equivalent is an `InfraEnv` in a namespace (plus pull secret). After it is ready:

```bash
oc get infraenv -A
oc get infraenv <name> -n <namespace> -o jsonpath='{.status.isoDownloadURL}{"\n"}'
```

Boot the NUC (or other host) from that ISO. Keep the ISO attached and set one-time boot from the virtual media / USB.

### Download URL shape

```text
https://assisted-image-service-multicluster-engine.nlb-apps.simon-demo.sandbox1133.opentlc.com/byapikey/<token>/4.22/x86_64/full.iso
```

Use **`nlb-apps`**, not **`apps`**. The token is an API key; do not commit it.

The OpenShift ingress certificate is not a public CA. From a NUC / laptop:

```bash
wget --no-check-certificate -O discovery.iso '<iso-url>'
```

Sanity check (in-cluster), without printing the token:

```bash
oc exec -n multicluster-engine deploy/assisted-service -c assisted-service -- \
  curl -skI --max-time 30 '<iso-url>'
```

You want `HTTP/1.1 200`, `content-disposition: attachment; filename=...-discovery.iso`, and a `content-length` around **1394606080** for the 4.22.0 x86_64 full ISO.

When the machine boots the ISO, an `Agent` appears in the same namespace as the `InfraEnv`.

```bash
oc get agents -A
```

---

## 6. Useful checks

```bash
# CIM / image service
oc get agentserviceconfig agent -o yaml
oc logs -n multicluster-engine assisted-image-service-0 --tail=50

# Ingress split
oc get ingresscontroller -n openshift-ingress-operator
oc get route -n multicluster-engine
oc get svc -n openshift-ingress
```

| Symptom | Likely cause |
| --- | --- |
| `assisted-image-service` 0/1, probe 503, logs “Downloading iso” for many arches | Default `osImages` catalog; pin x86_64 (or the arch you need) |
| PVC `Pending` | No default StorageClass / CSI driver |
| ISO wget hangs or resets on `*.apps.*` on AWS | Still on default LB; use `*.nlb-apps.*` |
| Route admitted by `default` and NLB | Default `routeSelector` still allows `router-type=nlb` |
| `curl` TLS error 60 / wget certificate warning | OpenShift ingress CA; `--no-check-certificate` / `-k` |

---

## What we did not put on the NLB

- `assisted-service` (API) stays on the default `*.apps.*` router.
- Console, OAuth, and other cluster routes stay on default.

Only the **Discovery ISO download** path needs the NLB.
