#!/usr/bin/env bash
# =============================================================================
# fix_bfd_redirects.sh
# -----------------------------------------------------------------------------
# BFD sessions stay Down even though config looks right? NX-OS warned us when
# we enabled 'feature bfd': 'no ip redirects' and 'no ipv6 redirects' are
# required on SVIs running BFD. With redirects on, BFD control packets take
# the wrong path and never reach the peer.
#
# This script adds those two lines to each leaf's Vlan SVI and then prints the
# current BFD state from every host. Expect 'Status: up' within a few seconds.
# =============================================================================
set -uo pipefail

readonly SW_USER="${SW_USER:-admin}"
readonly SW_PASS="${SW_PASS:-admin}"
readonly SSH_USER="${SSH_USER:-user}"

readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"
readonly SSH_OPTS_HOST="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes"

# name:svi:vlan
readonly LEAVES=(
  "Leaf-1:10.1.1.1:11"
  "Leaf-2:10.1.2.1:12"
  "Leaf-3:10.1.3.1:13"
  "Leaf-4:10.1.4.1:14"
)

# name:host-ip
readonly HOSTS=(
  "master:10.1.1.10"
  "worker-1:10.1.2.10"
  "worker-2:10.1.3.10"
  "worker-3:10.1.4.10"
)

# ---- display ----------------------------------------------------------------
BOLD=$'\033[1m'; NC=$'\033[0m'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'
banner()  { printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n  %s%s%s\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" \
              "$BOLD$MAGENTA" "$NC" "$BOLD$MAGENTA" "$*" "$NC" "$BOLD$MAGENTA" "$NC"; }
section() { printf "\n%s── %s%s\n" "$BOLD$CYAN" "$*" "$NC"; }
info()    { printf "%s[i]%s %s\n"  "$BLUE"   "$NC" "$*"; }
ok()      { printf "%s[+]%s %s\n"  "$GREEN"  "$NC" "$*"; }
warn()    { printf "%s[!]%s %s\n"  "$YELLOW" "$NC" "$*"; }
err()     { printf "%s[x]%s %s\n"  "$RED"    "$NC" "$*"; }

# ---- fix one leaf ----------------------------------------------------------
fix_leaf() {
  local name="$1" svi="$2" vlan="$3"
  section "$name (SVI $svi, Vlan$vlan)"

  local cfg
  cfg=$(cat <<CFG
terminal length 0
conf t
interface Vlan$vlan
  no ip redirects
  no ipv6 redirects
exit
end
copy running-config startup-config
show running-config interface Vlan$vlan
show bfd neighbors vrf tenant-1
exit
CFG
)
  local out
  out=$(timeout 30 sshpass -p "$SW_PASS" ssh -T $SSH_OPTS_NXOS "$SW_USER@$svi" <<<"$cfg" 2>&1) || true
  if [[ -z "$out" ]]; then
    err "$name: empty response"
    return 1
  fi
  echo "$out" | sed 's/^/    /'
  ok "$name: redirects disabled on Vlan$vlan"
}

# ---- verify from hosts -----------------------------------------------------
verify_host() {
  local name="$1" ip="$2"
  printf "\n%s-- %s --%s\n" "$BOLD" "$name" "$NC"
  local out
  out=$(ssh $SSH_OPTS_HOST "$SSH_USER@$ip" \
        "sudo vtysh -c 'show bfd peers'" 2>&1) || true
  echo "$out" | sed 's/^/    /'

  # one-line summary
  local status
  status=$(grep -oE 'Status: [a-z]+' <<<"$out" | head -1 | awk '{print $2}')
  case "$status" in
    up)       ok "$name: BFD UP" ;;
    down)     err "$name: still DOWN — check NX-OS side" ;;
    init)     warn "$name: INIT (negotiating, give it a sec)" ;;
    *)        warn "$name: unknown state '$status'" ;;
  esac
}

# ---- main -------------------------------------------------------------------
main() {
  banner "Fix: no ip/ipv6 redirects on leaf SVIs (BFD requirement)"
  command -v sshpass >/dev/null || { sudo apt-get install -y -qq sshpass; }

  for lf in "${LEAVES[@]}"; do
    IFS=: read -r name svi vlan <<<"$lf"
    fix_leaf "$name" "$svi" "$vlan" || true
  done

  banner "Verify BFD state on each host (~5s for convergence)"
  sleep 5
  local up=0 total="${#HOSTS[@]}"
  for h in "${HOSTS[@]}"; do
    IFS=: read -r name ip <<<"$h"
    verify_host "$name" "$ip"
    if ssh $SSH_OPTS_HOST "$SSH_USER@$ip" \
         "sudo vtysh -c 'show bfd peers' 2>&1 | grep -q 'Status: up'"; then
      up=$((up+1))
    fi
  done

  banner "Summary"
  if [[ "$up" -eq "$total" ]]; then
    ok "All $total/$total BFD sessions UP"
  else
    warn "$up/$total BFD sessions UP — re-run in 5-10s if some are still INIT"
    echo
    info "If still down after a minute, check on the NX-OS side:"
    echo "    sshpass -p admin ssh admin@10.1.1.1 'show bfd neighbors details vrf tenant-1'"
    echo "    and look for Rx/Tx packet counters climbing on both sides."
  fi
}

main "$@"
