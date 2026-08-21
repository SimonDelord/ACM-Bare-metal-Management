#!/usr/bin/env bash
# Program OVN load balancers on the primary UDN for the spoke API and ingress VIPs.
# There is no Kubernetes YAML for this: a Service cannot own 192.168.200.200/201.
set -euo pipefail

SWITCH=bare.metal.hosts_udn.l2.primary_ovn_layer2_switch
API_VIP=192.168.200.200
API_BACKEND=${API_BACKEND:-192.168.200.12}
INGRESS_VIP=192.168.200.201
# Ready masters (host-4 is still bootstrap). Comma-separated host:port is built below.
INGRESS_BACKENDS=${INGRESS_BACKENDS:-192.168.200.10 192.168.200.11}

http_backends=$(for ip in ${INGRESS_BACKENDS}; do printf '%s:80,' "$ip"; done | sed 's/,$//')
https_backends=$(for ip in ${INGRESS_BACKENDS}; do printf '%s:443,' "$ip"; done | sed 's/,$//')

nodes=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for pod in $nodes; do
  echo "==> ${pod}"
  oc exec -n openshift-ovn-kubernetes "${pod}" -c nbdb -- bash -c "
    ovn-nbctl --no-leader-only lb-del bm-spoke-api 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-mcs 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-ingress-http 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-ingress-https 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-add bm-spoke-api ${API_VIP}:6443 ${API_BACKEND}:6443 tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-mcs ${API_VIP}:22623 ${API_BACKEND}:22623 tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-ingress-http ${INGRESS_VIP}:80 ${http_backends} tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-ingress-https ${INGRESS_VIP}:443 ${https_backends} tcp
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-api 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-mcs 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-ingress-http 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-ingress-https 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-list ${SWITCH} | grep -E 'bm-spoke|VIP' || true
  " || echo "skip ${pod} (switch not local?)"
done
