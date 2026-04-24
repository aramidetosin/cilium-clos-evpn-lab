#!/usr/bin/env bash
# =============================================================================
# Render /etc/netplan/60-fabric.yaml on all 4 nodes and apply.
# Overwrites the file in full - keep VIP_POOLS up to date when adding pools.
# SSH from master to workers; master updates itself locally.
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
readonly VIP_POOLS=("192.168.0.0/16")     # supernet covers all present & future pools
readonly NETPLAN_FILE="/etc/netplan/60-fabric.yaml"
readonly MTU=9000

# name : ens4-ip/mask : leaf-svi
readonly NODES=(
  "master:10.1.1.10/24:10.1.1.1"
  "worker-1:10.1.2.10/24:10.1.2.1"
  "worker-2:10.1.3.10/24:10.1.3.1"
  "worker-3:10.1.4.10/24:10.1.4.1"
)

readonly SSH_USER="${SSH_USER:-user}"
readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# ---- helpers ----------------------------------------------------------------
GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
info() { printf "%s[i]%s %s\n" "$BLUE" "$NC" "$*"; }
ok()   { printf "%s[+]%s %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%s[!]%s %s\n" "$YELLOW" "$NC" "$*"; }

ssh_w() { local t="$1"; shift; ssh $SSH_OPTS "$SSH_USER@$t" "$@"; }

render() {
  local name="$1" addr="$2" svi="$3"
  {
    echo "# $NETPLAN_FILE on $name"
    echo "# ens4 = e1 = fabric to its leaf. Does NOT touch ens3 (cloud-init owns that)."
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    ens4:"
    echo "      dhcp4: false"
    echo "      addresses:"
    echo "        - $addr"
    echo "      mtu: $MTU"
    echo "      routes:"
    echo "        - to: 10.0.0.0/8"
    echo "          via: $svi"
    for pool in "${VIP_POOLS[@]}"; do
      echo "        - to: $pool"
      echo "          via: $svi"
    done
  }
}

# ---- run --------------------------------------------------------------------
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  rest="${entry#*:}"
  addr="${rest%%:*}"
  svi="${rest##*:}"
  ens4_ip="${addr%%/*}"

  info "$name ($addr -> $svi)"
  yaml="$(render "$name" "$addr" "$svi")"

  if [[ "$name" == "master" ]]; then
    echo "$yaml" | sudo tee "$NETPLAN_FILE" >/dev/null
    sudo chmod 600 "$NETPLAN_FILE"
    sudo netplan apply
  else
    echo "$yaml" | ssh_w "$ens4_ip" \
      "sudo tee $NETPLAN_FILE >/dev/null \
       && sudo chmod 600 $NETPLAN_FILE \
       && sudo netplan apply"
  fi
  ok "$name: applied"
done

echo
info "Verify on any node:"
echo "  ip route show dev ens4"
echo "  ip route get 192.168.100.0    # should now show: via <SVI> dev ens4"
echo
info "Cilium BGP sessions should stay established across netplan apply"
info "(ens4 IP unchanged, only a route added)."
