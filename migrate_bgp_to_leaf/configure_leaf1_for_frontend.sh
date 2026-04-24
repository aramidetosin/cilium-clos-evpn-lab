#!/usr/bin/env bash
# =============================================================================
# configure_leaf1_for_frontend.sh
# -----------------------------------------------------------------------------
# Configures Leaf-1 Ethernet1/4 as a routed L3 port in VRF tenant-1, for the
# newly-added frontend device.
#
# Design notes:
#  - Eth1/4 gets 192.168.255.1/30 — an IP INSIDE the 192.168.0.0/16 supernet.
#    This is deliberate: every host's kernel FIB already has
#    '192.168.0.0/16 via <local-leaf> proto bgp', so replies from pods to the
#    frontend (192.168.255.2) route back via the fabric without any new routes
#    on the hosts. Zero changes to host-side config.
#  - 'redistribute direct route-map PERMIT-ALL' (already in VRF tenant-1 AF
#    IPv4 unicast on Leaf-1) will pick up 192.168.255.0/30 as a direct route
#    and advertise it to the other leaves as EVPN type-5.
#  - K8S-HOST-OUT already permits anything in 192.168.0.0/16 le 32, so each
#    host learns 192.168.255.0/30 automatically.
# =============================================================================

set -uo pipefail

readonly SW_USER="${SW_USER:-admin}"
readonly SW_PASS="${SW_PASS:-admin}"
readonly LEAF_IP="${LEAF_IP:-10.1.1.1}"           # Leaf-1's SVI
readonly LEAF_PORT="${LEAF_PORT:-Ethernet1/4}"
readonly LEAF_P2P_IP="${LEAF_P2P_IP:-192.168.255.1/30}"
readonly FRONTEND_IP="${FRONTEND_IP:-192.168.255.2}"

readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"

BOLD=$'\033[1m'; NC=$'\033[0m'
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
banner()  { printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n  %s%s%s\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" \
              "$BOLD$MAGENTA" "$NC" "$BOLD$MAGENTA" "$*" "$NC" "$BOLD$MAGENTA" "$NC"; }
ok()   { printf "%s[+]%s %s\n" "$GREEN" "$NC" "$*"; }
info() { printf "%s[i]%s %s\n" "$BLUE"  "$NC" "$*"; }
err()  { printf "%s[x]%s %s\n" "$RED"   "$NC" "$*"; }

banner "Configure Leaf-1 $LEAF_PORT as frontend uplink"
info "   Leaf-1 Eth1/4 : $LEAF_P2P_IP (VRF tenant-1, routed)"
info "   Frontend      : $FRONTEND_IP"

cfg=$(cat <<CFG
terminal length 0
conf t
interface $LEAF_PORT
  description frontend ens4 (192.168.255.2)
  no switchport
  vrf member tenant-1
  no ip redirects
  ip address $LEAF_P2P_IP
  no ipv6 redirects
  no shutdown
end
copy running-config startup-config
show running-config interface $LEAF_PORT
show ip route 192.168.255.0/30 vrf tenant-1
exit
CFG
)

out=$(timeout 30 sshpass -p "$SW_PASS" \
      ssh -T $SSH_OPTS_NXOS "$SW_USER@$LEAF_IP" <<<"$cfg" 2>&1) || {
  err "SSH to Leaf-1 failed"
  echo "$out"
  exit 1
}

echo "$out" | sed 's/^/    /'

# Sanity: the interface should show up / up and 192.168.255.0/30 should be
# in the VRF RIB as direct.
if echo "$out" | grep -q "192.168.255.0/30, ubest"; then
  ok "Leaf-1: $LEAF_PORT is UP and 192.168.255.0/30 is in VRF tenant-1 RIB as direct"
else
  err "Leaf-1: /30 not yet in RIB — is the frontend e1 connected + up?"
  info "   If the cable isn't drawn yet in EVE-NG or the frontend isn't booted,"
  info "   this is expected. The interface will come up when the physical link is up."
fi

echo
info "Next steps:"
echo "   1) SSH into the frontend and run configure_frontend.sh"
echo "   2) curl http://192.168.100.0/ from the frontend"
