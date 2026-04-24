#!/usr/bin/env bash
# =============================================================================
# debug_bfd.sh
# -----------------------------------------------------------------------------
# BFD shows Remote-ID=0 on BOTH sides (NX-OS + FRR) even though BGP is up.
# This script:
#   1. Tcpdumps UDP/3784 on each host to see which direction the packets travel
#   2. Shows 'show bfd neighbors details' from each leaf (Tx/Rx counters)
#   3. Reports CoPP drops affecting BFD class
#   4. Applies the usual remedies:
#        - 'router bgp / bfd' at global level (NX-OS sometimes needs this)
#        - 'no bfd echo' on the SVI (echo mode fighting with async)
#        - Explicit 'update-source' on NX-OS neighbor for BFD
#        - clear bfd / clear bgp to force re-negotiation
#   5. Re-verifies
# =============================================================================
set -uo pipefail

readonly SW_USER="${SW_USER:-admin}"
readonly SW_PASS="${SW_PASS:-admin}"
readonly SSH_USER="${SSH_USER:-user}"
readonly TCPDUMP_SEC="${TCPDUMP_SEC:-4}"

readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"
readonly SSH_OPTS_HOST="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes"

# host-name:host-ip:leaf-svi:vlan
readonly PAIRS=(
  "master:10.1.1.10:10.1.1.1:11"
  "worker-1:10.1.2.10:10.1.2.1:12"
  "worker-2:10.1.3.10:10.1.3.1:13"
  "worker-3:10.1.4.10:10.1.4.1:14"
)

# ---- display ---------------------------------------------------------------
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

# ---- STAGE A: observe packets in flight ------------------------------------
stage_a_tcpdump() {
  banner "A. tcpdump UDP/3784 on each host ($TCPDUMP_SEC s)"
  info "We want to see packets going BOTH directions. Anything one-sided = path/drop issue."

  for p in "${PAIRS[@]}"; do
    IFS=: read -r name ip leaf _ <<<"$p"
    section "$name ($ip) ← → $leaf"
    # tcpdump in background, run in a short window
    local pcap
    pcap=$(ssh $SSH_OPTS_HOST "$SSH_USER@$ip" \
          "sudo timeout $TCPDUMP_SEC tcpdump -ni ens4 -c 100 -tt 'udp port 3784' 2>&1" || true)
    local sent_to_leaf recv_from_leaf
    sent_to_leaf=$(grep -cE "IP ${ip//./\\.}\\.[0-9]+ > ${leaf//./\\.}\\.3784" <<<"$pcap" || true)
    recv_from_leaf=$(grep -cE "IP ${leaf//./\\.}\\.3784 > ${ip//./\\.}\\." <<<"$pcap" || true)
    printf "    packets host → leaf:  %s\n" "$sent_to_leaf"
    printf "    packets leaf → host:  %s\n" "$recv_from_leaf"
    if [[ "$sent_to_leaf" -gt 0 && "$recv_from_leaf" -gt 0 ]]; then
      ok   "$name: bidirectional BFD traffic seen on wire"
    elif [[ "$sent_to_leaf" -gt 0 ]]; then
      err  "$name: host transmits but leaf is silent → NX-OS side broken (CoPP? BFD not triggered?)"
    elif [[ "$recv_from_leaf" -gt 0 ]]; then
      err  "$name: leaf transmits but host is silent → host kernel dropping (iptables? nftables?)"
    else
      err  "$name: NO BFD traffic on wire in either direction"
    fi
  done
}

# ---- STAGE B: NX-OS diagnostic dump -----------------------------------------
stage_b_nxos_diag() {
  banner "B. NX-OS-side diagnostics (detail + CoPP)"
  for p in "${PAIRS[@]}"; do
    IFS=: read -r name ip leaf _ <<<"$p"
    section "$leaf (peer for $name)"
    local cmd=$(cat <<NX
terminal length 0
show bfd neighbors vrf tenant-1 details
show policy-map interface control-plane class copp-system-p-class-monitoring | include class|conform|violate
show hardware internal forwarding l3 route vrf tenant-1 10.1.${leaf##*.}.10/32 2>/dev/null | head -20
exit
NX
)
    cmd="${cmd//10.1.\${leaf\#\#\*.\}/10.1.${leaf##10.1.}}"  # (no-op placeholder; keeping readable)
    local out
    out=$(timeout 30 sshpass -p "$SW_PASS" ssh -T $SSH_OPTS_NXOS "$SW_USER@$leaf" <<<"$cmd" 2>&1) || true
    echo "$out" | sed 's/^/    /'
  done
}

# ---- STAGE C: apply remedies -----------------------------------------------
stage_c_fixes() {
  banner "C. Apply remedies (no echo, global BGP bfd, clear)"
  for p in "${PAIRS[@]}"; do
    IFS=: read -r name hip leaf vlan <<<"$p"
    section "$leaf"
    local cfg=$(cat <<CFG
terminal length 0
conf t

! 1. Disable BFD echo mode on the SVI. Echo can conflict with plain async
!    single-hop BFD when the peer (FRR here) doesn't transmit echo packets.
interface Vlan$vlan
  no bfd echo
exit

! 2. Enable BFD at the 'router bgp' global level. Some NX-OS 10.x builds
!    require this in addition to the per-neighbor 'bfd' to actually wire
!    the BGP neighbor state-machine to BFD.
router bgp 65000
  bfd
  vrf tenant-1
    neighbor $hip
      bfd
    exit
  exit
exit

end
copy running-config startup-config

! 3. Clear the stuck BFD session + soft-reset BGP (no data-plane flap; just
!    re-negotiate the control protocols).
clear bfd session dest-ip $hip vrf tenant-1
clear ip bgp $hip vrf tenant-1 soft

exit
CFG
)
    local out
    out=$(timeout 30 sshpass -p "$SW_PASS" ssh -T $SSH_OPTS_NXOS "$SW_USER@$leaf" <<<"$cfg" 2>&1) || true
    echo "$out" | sed 's/^/    /'
    ok "$leaf: remedies applied"
  done

  info "Also clearing BFD on the FRR side..."
  for p in "${PAIRS[@]}"; do
    IFS=: read -r name hip _ _ <<<"$p"
    ssh $SSH_OPTS_HOST "$SSH_USER@$hip" \
        "sudo vtysh -c 'clear bgp *' 2>/dev/null" >/dev/null || true
  done

  info "Waiting 15s for sessions to re-establish..."
  sleep 15
}

# ---- STAGE D: re-verify -----------------------------------------------------
stage_d_verify() {
  banner "D. Verify BFD state post-fix"
  local up=0 total="${#PAIRS[@]}"
  for p in "${PAIRS[@]}"; do
    IFS=: read -r name hip leaf _ <<<"$p"
    section "$name"

    local host_state leaf_state
    host_state=$(ssh $SSH_OPTS_HOST "$SSH_USER@$hip" \
                 "sudo vtysh -c 'show bfd peers' 2>&1 | awk '/Status:/ {print \$2; exit}'" || echo unknown)
    leaf_state=$(timeout 10 sshpass -p "$SW_PASS" ssh -T $SSH_OPTS_NXOS "$SW_USER@$leaf" \
                 "show bfd neighbors vrf tenant-1" 2>&1 \
                 | awk -v hip="$hip" '$2==hip {print $7; exit}' || echo unknown)
    printf "    host (FRR) status:   %s\n" "$host_state"
    printf "    leaf (NX-OS) state:  %s\n" "$leaf_state"
    if [[ "$host_state" == "up" && "$leaf_state" == "Up" ]]; then
      ok "$name: BFD UP on both sides"
      up=$((up+1))
    else
      err "$name: not converged"
    fi
  done

  banner "Summary"
  if [[ "$up" -eq "$total" ]]; then
    ok "All $total/$total BFD sessions UP"
    return 0
  else
    err "$up/$total up — re-run stage A (tcpdump) to see if traffic is now flowing both ways."
    info "If packets still one-sided:"
    echo "   • host → leaf only: NX-OS is dropping on ingress — check CoPP with"
    echo "     sshpass -p admin ssh admin@<leaf> 'show policy-map interface control-plane | include bfd|drop'"
    echo "   • leaf → host only: host kernel dropping — check 'sudo nft list ruleset' or 'iptables -L -n -v'"
    echo "   • neither direction: NX-OS bfd daemon not scheduling — 'show bfd internal info' and restart feature:"
    echo "     conf t ; no feature bfd ; feature bfd ; end"
    return 1
  fi
}

# ---- main -------------------------------------------------------------------
main() {
  command -v sshpass >/dev/null || { sudo apt-get install -y -qq sshpass; }
  stage_a_tcpdump
  stage_b_nxos_diag
  stage_c_fixes
  stage_a_tcpdump      # run again post-fix to see if traffic changed
  stage_d_verify
}

main "$@"
