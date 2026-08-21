#!/usr/bin/env bash
# Program OVN load balancers on the primary UDN so 192.168.200.200:{6443,22623}
# DNAT to the bootstrap VM (192.168.200.12). There is no Kubernetes YAML for
# this: a Service cannot own 192.168.200.200, and externalIPs on this UDN are
# programmed with empty backends (connection refused).
set -euo pipefail

SWITCH=bare.metal.hosts_udn.l2.primary_ovn_layer2_switch
VIP=192.168.200.200
BACKEND=192.168.200.12

nodes=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for pod in $nodes; do
  echo "==> ${pod}"
  oc exec -n openshift-ovn-kubernetes "${pod}" -c nbdb -- bash -c "
    ovn-nbctl --no-leader-only lb-del bm-spoke-api 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-del bm-spoke-mcs 2>/dev/null || true
    ovn-nbctl --no-leader-only lb-add bm-spoke-api ${VIP}:6443 ${BACKEND}:6443 tcp
    ovn-nbctl --no-leader-only lb-add bm-spoke-mcs ${VIP}:22623 ${BACKEND}:22623 tcp
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-api 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-add ${SWITCH} bm-spoke-mcs 2>/dev/null || true
    ovn-nbctl --no-leader-only ls-lb-list ${SWITCH} | grep -E 'bm-spoke|VIP' || true
  " || echo "skip ${pod} (switch not local?)"
done
