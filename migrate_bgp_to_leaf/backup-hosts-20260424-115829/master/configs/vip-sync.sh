#!/usr/bin/env bash
# vip-sync: maintain /32 aliases on lo matching current K8s LB Service IPs.
# FRR's `redistribute connected route-map VIP-FILTER` advertises them.
set -uo pipefail
KUBECONFIG="/etc/vip-sync/kubeconfig"
SUPERNET_RE='^192\.168\.'          # adjust if you change VIP_SUPERNET
INTERVAL="${INTERVAL:-30}"

while true; do
  # Desired: all LB VIPs currently allocated (exclude system namespaces)
  desired=$(kubectl --kubeconfig="$KUBECONFIG" get svc -A \
    --field-selector spec.type=LoadBalancer \
    -o json 2>/dev/null | \
    jq -r '.items[]
      | select(.metadata.namespace != "kube-system" and .metadata.namespace != "kube-public")
      | .status.loadBalancer.ingress[0].ip // empty' \
    | sort -u)

  # Actual: /32s on lo that fall in our supernet (owned by this daemon)
  actual=$(ip -4 addr show dev lo 2>/dev/null | \
    awk -v re="$SUPERNET_RE" '/inet / { split($2,a,"/"); if (a[2]=="32" && a[1] ~ re) print a[1] }' \
    | sort -u)

  # Add missing
  while read -r vip; do
    [[ -z "$vip" ]] && continue
    if ! grep -qxF "$vip" <<<"$actual"; then
      ip addr add "$vip/32" dev lo 2>/dev/null && \
        logger -t vip-sync "added $vip/32 to lo"
    fi
  done <<<"$desired"

  # Remove stale
  while read -r addr; do
    [[ -z "$addr" ]] && continue
    if ! grep -qxF "$addr" <<<"$desired"; then
      ip addr del "$addr/32" dev lo 2>/dev/null && \
        logger -t vip-sync "removed $addr/32 from lo"
    fi
  done <<<"$actual"

  sleep "$INTERVAL"
done
