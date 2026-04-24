#!/usr/bin/env bash
# =============================================================================
# configure_frontend.sh
# -----------------------------------------------------------------------------
# Run THIS script on the frontend device (172.29.129.195).
#
# What it does:
#  1. Writes a netplan file that brings up ens4 with 192.168.255.2/30
#     and installs a static route to the entire VIP supernet (192.168.0.0/16)
#     via the Leaf-1 side of the P2P link (192.168.255.1).
#  2. netplan apply
#  3. Smoke-tests reachability to all four VIPs.
#
# Why 192.168.255.2 (an address inside the supernet)?
#   Pod replies destined to the frontend traverse the fabric using every
#   host's existing '192.168.0.0/16 proto bgp' FIB entry. If the frontend
#   had a mgmt-network IP as its fabric address, we'd need new host routes
#   everywhere. This keeps the hosts completely untouched.
# =============================================================================

set -euo pipefail

readonly ENS4_IP="192.168.255.2/30"
readonly LEAF_GW="192.168.255.1"
readonly VIP_SUPERNET="192.168.0.0/16"
readonly NETPLAN_FILE="/etc/netplan/60-fabric.yaml"

BOLD=$'\033[1m'; NC=$'\033[0m'
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[0;33m'; MAGENTA=$'\033[0;35m'
banner()  { printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n  %s%s%s\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" \
              "$BOLD$MAGENTA" "$NC" "$BOLD$MAGENTA" "$*" "$NC" "$BOLD$MAGENTA" "$NC"; }
ok()   { printf "%s[+]%s %s\n" "$GREEN"  "$NC" "$*"; }
info() { printf "%s[i]%s %s\n" "$BLUE"   "$NC" "$*"; }
warn() { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }
err()  { printf "%s[x]%s %s\n" "$RED"    "$NC" "$*"; }

banner "Frontend fabric setup"

# 0. Preflight
if ! ip link show ens4 >/dev/null 2>&1; then
  err "ens4 not found. Did you add a second interface in EVE-NG and reboot?"
  err "   Run 'ip link' to see what interfaces exist."
  exit 1
fi
info "ens4 is present"

if [[ $EUID -ne 0 ]]; then
  err "This script needs root. Re-run with: sudo $0"
  exit 1
fi

# 1. Write netplan config
info "writing $NETPLAN_FILE"
cat > "$NETPLAN_FILE" <<YAML
# Fabric edge link to Leaf-1 Eth1/4 (VRF tenant-1)
# Uses an IP inside 192.168.0.0/16 so pod replies traverse the existing
# BGP-installed supernet route on each K8s host — no host-side changes needed.
network:
  version: 2
  ethernets:
    ens4:
      dhcp4: false
      dhcp6: false
      accept-ra: false
      addresses:
        - $ENS4_IP
      routes:
        - to: $VIP_SUPERNET
          via: $LEAF_GW
          metric: 100
YAML
chmod 600 "$NETPLAN_FILE"
ok "netplan file written"

# 2. Apply
info "running netplan apply (ens3 mgmt connection will remain)"
netplan apply
sleep 2

# 3. Verify kernel state
echo
info "ens4 state:"
ip -4 addr show ens4 | sed 's/^/    /'
echo
info "relevant routes:"
ip -4 route show | grep -E "(192\.168\.|192\.168\.255\.0/30)" | sed 's/^/    /' || true

# 4. Can we reach the leaf SVI?
echo
info "pinging Leaf-1 edge ($LEAF_GW)..."
if ping -c 2 -W 2 "$LEAF_GW" >/dev/null 2>&1; then
  ok "Leaf-1 edge reachable"
else
  err "Leaf-1 edge $LEAF_GW unreachable"
  err "   Check: (a) EVE-NG cable from frontend:e1 to Leaf-1:Eth1/4 is drawn"
  err "          (b) Leaf-1 Eth1/4 was configured (run configure_leaf1_for_frontend.sh)"
  err "          (c) 'ip link show ens4' says 'state UP'"
  exit 1
fi

# 5. Smoke test: curl each VIP
echo
banner "VIP reachability smoke test"
declare -A SVC=(
  ["192.168.100.0"]="param-server"
  ["192.168.100.1"]="trainer"
  ["192.168.100.2"]="inference"
  ["192.168.100.3"]="data-loader"
)

passed=0; total=0
for vip in "${!SVC[@]}"; do
  total=$((total+1))
  svc="${SVC[$vip]}"
  printf "   curl http://%s/ (%s)%*s → " "$vip" "$svc" $((14 - ${#svc})) " "
  resp=$(curl -s --max-time 5 "http://$vip/" 2>&1) || resp=""
  if [[ -n "$resp" ]]; then
    printf "%s✓%s %s\n" "$GREEN" "$NC" "$resp"
    passed=$((passed+1))
  else
    printf "%s✗%s no response\n" "$RED" "$NC"
  fi
done

echo
if [[ $passed -eq $total ]]; then
  banner "SUCCESS — $passed/$total VIPs reachable from the frontend"
  info "traceroute confirmation (optional):"
  info "   traceroute 192.168.100.0"
  info "   expected: 1) $LEAF_GW  2) <master fabric IP>  3) the VIP itself"
else
  banner "PARTIAL — $passed/$total VIPs reachable"
  warn "Troubleshooting:"
  echo "   • Leaf-1 BGP to master should be Established:"
  echo "       sshpass -p admin ssh admin@10.1.1.1 'show bgp ipv4 unicast summary vrf tenant-1'"
  echo "   • VIPs should show *>e via 10.1.1.10 on Leaf-1:"
  echo "       sshpass -p admin ssh admin@10.1.1.1 'show ip bgp vrf tenant-1 | include 192.168.100'"
  echo "   • On master, the reverse path should work:"
  echo "       ssh user@10.1.1.10 'ip route get 192.168.255.2'"
fi
