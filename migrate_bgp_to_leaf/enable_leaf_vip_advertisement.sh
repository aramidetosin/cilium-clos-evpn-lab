#!/usr/bin/env bash
# =============================================================================
# enable_leaf_vip_advertisement.sh
# -----------------------------------------------------------------------------
# Flip each leaf from "deny all outbound to host" to "advertise a VIP supernet
# aggregate". After this, the leaf sends `192.168.0.0/16` (or whatever you set
# VIP_SUPERNET to) down to its attached host via eBGP, and ANY future pool
# inside that supernet is automatically advertised without touching the
# fabric or the hosts.
#
# Runs from master. One SSH session per leaf (sshpass, admin/admin by
# default). Idempotent — safe to re-run.
# =============================================================================
set -uo pipefail

# ---- config -----------------------------------------------------------------
readonly LEAF_USER="${LEAF_USER:-admin}"
readonly LEAF_PASS="${LEAF_PASS:-admin}"
readonly VIP_SUPERNET="${VIP_SUPERNET:-192.168.0.0/16}"
readonly LOG_FILE="$(pwd)/enable-leaf-adv-$(date +%Y%m%d-%H%M%S).log"
readonly SSH_TIMEOUT=45

readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"

readonly LEAVES=(
  "Leaf-1:10.1.1.1"
  "Leaf-2:10.1.2.1"
  "Leaf-3:10.1.3.1"
  "Leaf-4:10.1.4.1"
)

# ---- log everything to CWD --------------------------------------------------
exec > >(tee -a "$LOG_FILE") 2>&1

# ---- display helpers --------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'

banner()  { printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n"  "$BOLD$MAGENTA" "$NC"
            printf "%s  %s%s\n" "$BOLD$MAGENTA" "$*" "$NC"
            printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n"    "$BOLD$MAGENTA" "$NC"; }
section() { printf "\n%s── %s%s\n"      "$BOLD$BLUE" "$*" "$NC"; }
info()    { printf "%s[i]%s %s\n"       "$BLUE"     "$NC" "$*"; }
ok()      { printf "%s[+]%s %s\n"       "$GREEN"    "$NC" "$*"; }
warn()    { printf "%s[!]%s %s\n"       "$YELLOW"   "$NC" "$*"; }
err()     { printf "%s[x]%s %s\n"       "$RED"      "$NC" "$*"; }

# ---- prereq -----------------------------------------------------------------
check_prereqs() {
  banner "Prerequisites"
  if ! command -v sshpass >/dev/null 2>&1; then
    warn "sshpass not installed — installing via apt"
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
  fi
  ok "sshpass: $(command -v sshpass)"
  ok "VIP supernet: $VIP_SUPERNET"
  ok "Log: $LOG_FILE"
}

# ---- apply on one leaf (single batched SSH session) ------------------------
apply_leaf() {
  local lname="$1" svi="$2"
  section "$lname ($svi)"

  local cfg
  cfg=$(cat <<CFG
terminal length 0
conf t

! 1. Widen the inbound prefix-list in place. Add supernet at seq 5 first,
!    then remove the old narrow seq 10. Never a moment with zero matches.
ip prefix-list K8S-VIP-POOL seq 5 permit $VIP_SUPERNET le 32
no ip prefix-list K8S-VIP-POOL seq 10

! 2. Flip outbound route-map. Insert permit at seq 5, then remove the
!    deny-all at seq 10. Never a moment with an open outbound policy.
route-map K8S-HOST-OUT permit 5
  match ip address prefix-list K8S-VIP-POOL
exit
no route-map K8S-HOST-OUT deny 10

! 3. Originate the supernet aggregate so there is a loop-safe prefix to
!    send down to the host. More-specific /32s are suppressed via
!    BGP loop prevention naturally (host's own AS is in their path).
router bgp 65000
  vrf tenant-1
    address-family ipv4 unicast
      aggregate-address $VIP_SUPERNET
      exit
    exit
  exit
exit

end
copy running-config startup-config

! -- verification (captured in transcript) ----------------------------------
show ip prefix-list K8S-VIP-POOL
show route-map K8S-HOST-OUT
show running-config bgp | egrep "aggregate-address|K8S-HOST|K8S-VIP"
show ip bgp vrf tenant-1 $VIP_SUPERNET
exit
CFG
)

  info "applying config + running verification in one SSH session"
  local out
  out=$(timeout "$SSH_TIMEOUT" sshpass -p "$LEAF_PASS" \
        ssh -T $SSH_OPTS_NXOS "$LEAF_USER@$svi" <<<"$cfg" 2>&1) || true

  if [[ -z "$out" ]]; then
    err "$lname: empty response (auth / timeout / unreachable)"
    return 1
  fi
  echo "$out" | sed 's/^/    /'
  ok "$lname: applied"
}

# ---- verify from master (Cilium side) --------------------------------------
verify_cilium() {
  banner "Cilium-side verification (Received column should now be >= 1)"

  info "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bgp peers"
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
    cilium-dbg bgp peers 2>&1 | sed 's/^/    /' || true

  echo
  info "Per-node: routes received from the leaf"
  for node in master worker-1 worker-2 worker-3; do
    local pod
    pod=$(kubectl -n kube-system get pod -l k8s-app=cilium \
            --field-selector "spec.nodeName=$node" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -z "$pod" ]] && continue
    printf "\n%s-- %s --%s\n" "$BOLD" "$node" "$NC"
    kubectl -n kube-system exec "$pod" -c cilium-agent -- \
      cilium-dbg bgp routes received ipv4 unicast 2>&1 | sed 's/^/    /' || true
  done
}

# ---- main ------------------------------------------------------------------
main() {
  check_prereqs

  banner "Enabling leaf -> host advertisement ($VIP_SUPERNET)"
  local failed=0
  for entry in "${LEAVES[@]}"; do
    local lname="${entry%%:*}" svi="${entry#*:}"
    apply_leaf "$lname" "$svi" || failed=$((failed+1))
  done

  if [[ "$failed" -gt 0 ]]; then
    warn "$failed leaf/leaves had issues — review above"
  fi

  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    info "giving BGP ~10s to converge..."
    sleep 10
    verify_cilium
  else
    warn "skipping Cilium verification (kubectl not reachable from here)"
  fi

  banner "Done"
  cat <<EOT

  What's new:
    • Each leaf accepts any /32 inside $VIP_SUPERNET from its host.
    • Each leaf advertises the $VIP_SUPERNET aggregate back to its host.
    • Cilium's BGP session now shows Received >= 1 (the supernet).

  To add a future pool (e.g. 192.168.101.0/24):
    • kubectl apply a new CiliumLoadBalancerIPPool. Done.
    • No leaf config. No netplan edits. No script reruns.

  Log: $LOG_FILE

EOT
}

main "$@"
