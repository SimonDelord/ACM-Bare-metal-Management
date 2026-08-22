#!/usr/bin/env bash
# Program OVN load balancers on the primary UDN for spoke API/MCS (.200) and ingress (.201).
# There is no Kubernetes YAML for this: a Service cannot own 192.168.200.200/201.
set -euo pipefail

SWITCH=bare.metal.hosts_udn.l2.primary_ovn_layer2_switch
API_VIP=192.168.200.200
API_BACKENDS=${API_BACKENDS:-192.168.200.10 192.168.200.11 192.168.200.12}
INGRESS_VIP=192.168.200.201
# Masters that currently serve API/MCS/router. Move API and MCS together; never
# leave 22623/22624 on a node that is itself fetching ignition.
INGRESS_BACKENDS=${INGRESS_BACKENDS:-192.168.200.10 192.168.200.11 192.168.200.12}

api_backends=$(for ip in ${API_BACKENDS}; do printf '%s:6443,' "$ip"; done | sed 's/,$//')
mcs_backends=$(for ip in ${API_BACKENDS}; do printf '%s:22623,' "$ip"; done | sed 's/,$//')
mcs_http_backends=$(for ip in ${API_BACKENDS}; do printf '%s:22624,' "$ip"; done | sed 's/,$//')
http_backends=$(for ip in ${INGRESS_BACKENDS}; do printf '%s:80,' "$ip"; done | sed 's/,$//')
https_backends=$(for ip in ${INGRESS_BACKENDS}; do printf '%s:443,' "$ip"; done | sed 's/,$//')

nodes=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for pod in $nodes; do
  echo "==> ${pod}"
  oc exec -n openshift-ovn-kubernetes "${pod}" -c nbdb -- bash -c "
    ovn-nbctl --no-leader-only lb-del bm-spoke-api 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-mcs 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-mcs-http 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-ingress-http 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-ingress-https 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-add bm-spoke-api ${API_VIP}:6443 ${api_backends} tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-mcs ${API_VIP}:22623 ${mcs_backends} tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-mcs-http ${API_VIP}:22624 ${mcs_http_backends} tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-ingress-http ${INGRESS_VIP}:80 ${http_backends} tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-ingress-https ${INGRESS_VIP}:443 ${https_backends} tcp
    ovn-nbctl --no-leader-only set Load_Balancer bm-spoke-api options:neighbor_responder=all
    ovn-nbctl --no-leader-only set Load_Balancer bm-spoke-mcs options:neighbor_responder=all
    ovn-nbctl --no-leader-only set Load_Balancer bm-spoke-mcs-http options:neighbor_responder=all
    ovn-nbctl --no-leader-only set Load_Balancer bm-spoke-ingress-http options:neighbor_responder=all
    ovn-nbctl --no-leader-only set Load_Balancer bm-spoke-ingress-https options:neighbor_responder=all
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-api 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-mcs 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-mcs-http 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-ingress-http 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-ingress-https 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-list ${SWITCH} | grep -E 'bm-spoke|VIP' || true
  " || echo "skip ${pod} (switch not local?)"
done
