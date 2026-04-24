#!/usr/bin/env bash
# =============================================================================
# Migrate Cilium BGP: node-to-node full-mesh  ->  node-to-leaf eBGP
# =============================================================================
# Run this script FROM the master host (10.1.1.10).
# Uses passwordless SSH + NOPASSWD sudo on worker-1/2/3 for verification.
# All Cilium changes are kubectl-from-master; SSH is only used for marquee.
#
# Target topology:
#   master   10.1.1.10  ens4 --ebGP-> Leaf-1 SVI 10.1.1.1  (AS 65201 <-> 65000)
#   worker-1 10.1.2.10  ens4 --ebGP-> Leaf-2 SVI 10.1.2.1  (AS 65202 <-> 65000)
#   worker-2 10.1.3.10  ens4 --ebGP-> Leaf-3 SVI 10.1.3.1  (AS 65203 <-> 65000)
#   worker-3 10.1.4.10  ens4 --ebGP-> Leaf-4 SVI 10.1.4.1  (AS 65204 <-> 65000)
#
# What this script does (cluster side):
#   - Rewrites the 4 CiliumBGPClusterConfigs to peer each node with its leaf
#   - Updates the CiliumBGPPeerConfig (single-hop eBGP, ebgpMultihop=2)
#   - Drops the "bgp-announce=true" label requirement on the advertisement
#   - Scopes the LB pool to exclude kube-system / kube-public via pseudo-label
#   - Leaves cluster, Cilium install, workloads untouched
#
# What you must do separately (fabric side):
#   - Paste the generated NX-OS block into each of Leaf-1..Leaf-4.
#     File is written to $LAB_DIR/fabric/host-bgp.cfg.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
readonly LAB_DIR="$(pwd)/leaf-bgp-migration"
readonly MANIFESTS_DIR="${LAB_DIR}/manifests"
readonly FABRIC_DIR="${LAB_DIR}/fabric"
readonly LOGS_DIR="${LAB_DIR}/logs"

readonly VIP_POOL_CIDR="192.168.100.0/24"
readonly POOL_NAME="ai-vip-pool"
readonly FABRIC_ASN="65000"

# Nodes:   hostname : ens4-ip    : asn   : leaf-svi
readonly MASTER="master:10.1.1.10:65201:10.1.1.1"
readonly WORKER_1="worker-1:10.1.2.10:65202:10.1.2.1"
readonly WORKER_2="worker-2:10.1.3.10:65203:10.1.3.1"
readonly WORKER_3="worker-3:10.1.4.10:65204:10.1.4.1"
readonly NODES=("$MASTER" "$WORKER_1" "$WORKER_2" "$WORKER_3")
readonly WORKERS=("$WORKER_1" "$WORKER_2" "$WORKER_3")

# Leaves:  leaf-name : leaf-svi : host-ip   : host-asn : host-name
readonly LEAF_1="Leaf-1:10.1.1.1:10.1.1.10:65201:master"
readonly LEAF_2="Leaf-2:10.1.2.1:10.1.2.10:65202:worker-1"
readonly LEAF_3="Leaf-3:10.1.3.1:10.1.3.10:65203:worker-2"
readonly LEAF_4="Leaf-4:10.1.4.1:10.1.4.10:65204:worker-3"
readonly LEAVES=("$LEAF_1" "$LEAF_2" "$LEAF_3" "$LEAF_4")

readonly SSH_USER="${SSH_USER:-user}"
readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
INTERACTIVE=false
CLEANUP_ONLY=false
SKIP_FABRIC_REMINDER=false

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Migrate Cilium BGP from node-to-node full-mesh to node-to-leaf peering.
VIPs are re-originated into the VXLAN EVPN fabric as type-5 routes.

Options:
  --cleanup                  Revert to original full-mesh configuration.
  --interactive              Pause between phases.
  --no-pause                 Default. Run to completion.
  --skip-fabric-reminder     Skip the "paste into leaves" prompt (use when
                             fabric side is already applied).
  -h, --help

Run from master. Requires passwordless SSH + NOPASSWD sudo on the 3 workers.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)              CLEANUP_ONLY=true; shift ;;
    --interactive)          INTERACTIVE=true;  shift ;;
    --no-pause)             INTERACTIVE=false; shift ;;
    --skip-fabric-reminder) SKIP_FABRIC_REMINDER=true; shift ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

# -----------------------------------------------------------------------------
# Display helpers (stderr)
# -----------------------------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; MAGENTA=$'\033[0;35m'
BOLD=$'\033[1m'; NC=$'\033[0m'

section() { printf "\n%s========================================================%s\n" "${BOLD}${BLUE}" "${NC}" >&2
            printf "%s  %s%s\n" "${BOLD}${BLUE}" "$*" "${NC}" >&2
            printf "%s========================================================%s\n" "${BOLD}${BLUE}" "${NC}" >&2; }
step()    { printf "\n%s--- %s ---%s\n" "${BOLD}${CYAN}" "$*" "${NC}" >&2; }
info()    { printf "%s[i]%s %s\n" "${BLUE}" "${NC}" "$*" >&2; }
success() { printf "%s[+]%s %s\n" "${GREEN}" "${NC}" "$*" >&2; }
warn()    { printf "%s[!]%s %s\n" "${YELLOW}" "${NC}" "$*" >&2; }
error()   { printf "%s[x]%s %s\n" "${RED}" "${NC}" "$*" >&2; }

show_file() {
  local file="$1"
  printf "%s  +-- %s%s\n" "${MAGENTA}" "$file" "${NC}" >&2
  sed 's/^/  | /' "$file" >&2
  printf "%s  +--%s\n" "${MAGENTA}" "${NC}" >&2
}

pause() {
  if [[ "$INTERACTIVE" == "true" ]]; then
    printf "%s  [paused] Press Enter...%s\n" "${YELLOW}" "${NC}" >&2
    read -r _ || true
  fi
}

# -----------------------------------------------------------------------------
# SSH + record helpers
# -----------------------------------------------------------------------------
ssh_w() { local t="$1"; shift; ssh $SSH_OPTS "$SSH_USER@$t" "$@"; }

# Node record fields
n_name() { echo "$1" | cut -d: -f1; }
n_ip()   { echo "$1" | cut -d: -f2; }
n_asn()  { echo "$1" | cut -d: -f3; }
n_leaf() { echo "$1" | cut -d: -f4; }

# Leaf record fields
l_name()    { echo "$1" | cut -d: -f1; }
l_svi()     { echo "$1" | cut -d: -f2; }
l_host_ip() { echo "$1" | cut -d: -f3; }
l_host_as() { echo "$1" | cut -d: -f4; }
l_host_nm() { echo "$1" | cut -d: -f5; }

# Find a cilium-agent pod on a given node
cilium_pod_on() {
  local node="$1"
  kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$node" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Phase 0: Prerequisite check
# -----------------------------------------------------------------------------
check_prereqs() {
  section "Phase 0: Prerequisite check"
  local failed=0
  local master_ip="$(n_ip "$MASTER")"

  if ! ip -4 addr show ens4 2>/dev/null | grep -q "$master_ip"; then
    error "This script must run on master ($master_ip on ens4)"
    exit 1
  fi
  success "Running on master ($master_ip)"

  if ! kubectl get nodes >/dev/null 2>&1; then
    error "kubectl cannot reach the cluster"
    exit 1
  fi
  success "kubectl OK"

  if ! kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
    error "Cilium daemonset not found in kube-system"
    exit 1
  fi
  success "Cilium daemonset present"

  # Soft check: nodes Ready
  local not_ready
  not_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready"' | wc -l)"
  if [[ "$not_ready" -gt 0 ]]; then
    warn "$not_ready node(s) not Ready - check 'kubectl get nodes'"
  else
    success "All nodes Ready"
  fi

  # SSH to workers
  for w in "${WORKERS[@]}"; do
    local wname="$(n_name "$w")" wip="$(n_ip "$w")"
    if ! ssh_w "$wip" "hostname" >/dev/null 2>&1; then
      error "$wname ($wip): SSH as '$SSH_USER' failed"
      failed=$((failed+1))
    else
      success "$wname: SSH OK"
    fi
  done

  [[ $failed -gt 0 ]] && { error "Fix the above and rerun"; exit 1; }
  pause
}

# -----------------------------------------------------------------------------
# Phase 1: Lab directory
# -----------------------------------------------------------------------------
setup_dirs() {
  section "Phase 1: Lab directory"
  mkdir -p "$MANIFESTS_DIR" "$FABRIC_DIR" "$LOGS_DIR"
  info "LAB_DIR=$LAB_DIR"
  pause
}

# -----------------------------------------------------------------------------
# Phase 2: Write fabric-side NX-OS config and prompt to apply
# -----------------------------------------------------------------------------
write_fabric_config() {
  section "Phase 2: Fabric-side NX-OS config (apply on each leaf)"

  local cfg="$FABRIC_DIR/host-bgp.cfg"
  cat > "$cfg" <<'HDR'
! =============================================================================
!  Fabric-side BGP peering with Cilium on Kubernetes hosts.
!  Paste the matching block into each leaf. Safe to re-apply.
!
!  Per-leaf additions:
!    - K8S-VIP-POOL prefix-list: restricts what the host can advertise
!    - K8S-HOST-IN (permit pool), K8S-HOST-OUT (deny everything)
!    - maximum-paths ibgp 4 in VRF tenant-1 (ECMP across 4 leaves per VIP)
!    - neighbor under "router bgp 65000 / vrf tenant-1"
!
!  TO ADD ANOTHER VIP POOL LATER:
!    ip prefix-list K8S-VIP-POOL seq 20 permit <new-cidr> le 32
! =============================================================================

HDR

  for l in "${LEAVES[@]}"; do
    local lname="$(l_name "$l")" svi="$(l_svi "$l")"
    local hip="$(l_host_ip "$l")" has="$(l_host_as "$l")" hnm="$(l_host_nm "$l")"

    cat >> "$cfg" <<EOF

! ----- $lname  (host: $hnm $hip AS $has, SVI $svi) ----------------------------
conf t

ip prefix-list K8S-VIP-POOL seq 10 permit $VIP_POOL_CIDR le 32

route-map K8S-HOST-IN permit 10
  match ip address prefix-list K8S-VIP-POOL

route-map K8S-HOST-OUT deny 10

router bgp $FABRIC_ASN
  vrf tenant-1
    address-family ipv4 unicast
      maximum-paths ibgp 4
    neighbor $hip
      remote-as $has
      description $hnm (Cilium BGP)
      timers 10 30
      address-family ipv4 unicast
        send-community
        send-community extended
        route-map K8S-HOST-IN in
        route-map K8S-HOST-OUT out
        soft-reconfiguration inbound always

end
copy running-config startup-config

EOF
  done

  info "fabric config written: $cfg"

  if [[ "$SKIP_FABRIC_REMINDER" == "true" ]]; then
    warn "Skipping fabric-side reminder (--skip-fabric-reminder)"
    return 0
  fi

  cat >&2 <<EOF

  ${BOLD}${YELLOW}ACTION REQUIRED${NC}

  Log into each of Leaf-1..Leaf-4 (console or SSH on mgmt VRF) and paste
  the matching block from:

    $cfg

  The four BGP neighbors will sit in Idle/Active until Cilium is swung
  over in the next phase. That is expected.

EOF
  printf "%s  Press Enter once all 4 leaves are configured... %s" "$YELLOW" "$NC" >&2
  read -r _ || true
}

# -----------------------------------------------------------------------------
# Phase 3: Generate Cilium manifests
# -----------------------------------------------------------------------------
generate_manifests() {
  section "Phase 3: Generate Cilium manifests"

  # --- CiliumLoadBalancerIPPool ---------------------------------------------
  # Authoritative namespace gate. Cilium's LB IPAM enriches each service with
  # io.kubernetes.service.namespace as a pseudo-label when evaluating the
  # pool's serviceSelector. Anything in kube-system/kube-public that asks for
  # type LoadBalancer simply won't get an IP from this pool.
  cat > "$MANIFESTS_DIR/lb-pool.yaml" <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: $POOL_NAME
spec:
  blocks:
  - cidr: $VIP_POOL_CIDR
  serviceSelector:
    matchExpressions:
    - key: io.kubernetes.service.namespace
      operator: NotIn
      values: [kube-system, kube-public]
EOF

  # --- CiliumBGPPeerConfig ---------------------------------------------------
  # Shared config. Single-hop eBGP to the leaf SVI; keep the multihop margin
  # tiny. Timers match the NX-OS side.
  cat > "$MANIFESTS_DIR/bgp-peer-config.yaml" <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: cluster-peer
spec:
  ebgpMultihop: 2
  timers:
    holdTimeSeconds: 30
    keepAliveTimeSeconds: 10
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: bgp
EOF

  # --- CiliumBGPAdvertisement -----------------------------------------------
  # Explicit match-all selector ({}): the pool already gates namespaces, so
  # every LB VIP in the cluster is in an allowed namespace and should be
  # advertised. Note: omitting `selector:` altogether deserializes to nil,
  # which k8s' LabelSelectorAsSelector treats as labels.Nothing() (matches
  # zero services). `{}` is a non-nil empty LabelSelector = match-all.
  cat > "$MANIFESTS_DIR/bgp-advertisement.yaml" <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: lb-vip-advertisement
  labels:
    advertise: bgp
spec:
  advertisements:
  - advertisementType: Service
    service:
      addresses:
      - LoadBalancerIP
    selector: {}
EOF

  # --- CiliumBGPClusterConfig x 4 -------------------------------------------
  # Each node peers single-hop eBGP with its directly-attached leaf SVI.
  # Replaces the previous full-mesh ClusterConfigs (same object names).
  local out="$MANIFESTS_DIR/bgp-cluster-configs.yaml"
  cat > "$out" <<'HDR'
# 4 CiliumBGPClusterConfigs, one per node. Overwrites the full-mesh
# configs that share these names (bgp-master, bgp-worker-[1-3]).
HDR

  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" nas="$(n_asn "$n")" leaf="$(n_leaf "$n")"
    cat >> "$out" <<EOF
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: bgp-$nname
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: $nname
  bgpInstances:
  - name: instance-$nname
    localASN: $nas
    localPort: 179
    peers:
    - name: leaf
      peerASN: $FABRIC_ASN
      peerAddress: $leaf
      peerConfigRef:
        name: cluster-peer
EOF
  done

  for f in lb-pool.yaml bgp-peer-config.yaml bgp-advertisement.yaml bgp-cluster-configs.yaml; do
    show_file "$MANIFESTS_DIR/$f"
  done
  pause
}

# -----------------------------------------------------------------------------
# Phase 4: Apply manifests (overwrites existing same-named objects)
# -----------------------------------------------------------------------------
apply_manifests() {
  section "Phase 4: Apply Cilium manifests"

  for f in lb-pool.yaml bgp-peer-config.yaml bgp-advertisement.yaml bgp-cluster-configs.yaml; do
    info "kubectl apply -f $f"
    kubectl apply -f "$MANIFESTS_DIR/$f" 2>&1 | sed 's/^/  /' >&2
  done
  success "applied"
  pause
}

# -----------------------------------------------------------------------------
# Phase 5: Verify BGP sessions established
# -----------------------------------------------------------------------------
verify_peering() {
  section "Phase 5: Verify BGP sessions"
  info "Waiting 30s for sessions to reconverge..."
  sleep 30

  local all_up=true
  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" leaf="$(n_leaf "$n")"
    local pod; pod="$(cilium_pod_on "$nname")"
    [[ -z "$pod" ]] && { warn "no cilium pod on $nname"; all_up=false; continue; }

    printf "\n%s--- %s  (peer: %s) ---%s\n" "$BOLD" "$nname" "$leaf" "$NC" >&2
    local out
    out="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- \
           cilium-dbg bgp peers 2>&1 || true)"
    echo "$out" | sed 's/^/  /' >&2

    if echo "$out" | grep -iq "established"; then
      success "$nname <-> $leaf: established"
    else
      warn "$nname <-> $leaf: NOT established"
      all_up=false
    fi
  done

  if [[ "$all_up" != "true" ]]; then
    warn "One or more sessions are down. Common causes:"
    warn "  - Fabric-side config not pasted yet"
    warn "  - Host AS vs remote-as mismatch on the leaf"
    warn "  - K8S-HOST-IN route-map filtering the prefix (wrong pool CIDR?)"
    warn "  - Cilium agent lacking NET_BIND_SERVICE capability"
  fi
  pause
}

# -----------------------------------------------------------------------------
# Phase 6: Verify routes advertised by each node
# -----------------------------------------------------------------------------
verify_advertised() {
  section "Phase 6: Routes advertised by each node"

  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")"
    local pod; pod="$(cilium_pod_on "$nname")"
    [[ -z "$pod" ]] && continue
    printf "\n%s--- %s advertised ---%s\n" "$BOLD" "$nname" "$NC" >&2
    kubectl -n kube-system exec "$pod" -c cilium-agent -- \
            cilium-dbg bgp routes advertised ipv4 unicast 2>&1 \
            | sed 's/^/  /' >&2 || true
  done

  step "All LoadBalancer Services (excluding system namespaces)"
  kubectl get svc -A --no-headers 2>/dev/null \
    | awk '$1 != "kube-system" && $1 != "kube-public" && $3 == "LoadBalancer"' \
    | sed 's/^/  /' >&2 || true

  pause
}

# -----------------------------------------------------------------------------
# Phase 7: Marquee - curl every VIP from every host
# -----------------------------------------------------------------------------
marquee_test() {
  section "Phase 7: Marquee - curl every VIP from every host"

  local vips
  vips="$(kubectl get svc -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    | grep -v '=$' | grep -vE '^(kube-system|kube-public)/' || true)"

  if [[ -z "$vips" ]]; then
    warn "No LoadBalancer VIPs allocated; skipping marquee"
    return 0
  fi

  step "VIPs"
  echo "$vips" | sed 's/^/  /' >&2

  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" nip="$(n_ip "$n")"
    step "From $nname ($nip)"
    while IFS='=' read -r svc vip; do
      [[ -z "$svc" || -z "$vip" ]] && continue
      local result
      if [[ "$nname" == "master" ]]; then
        result="$(curl -s --max-time 5 "http://$vip/" 2>&1 || true)"
      else
        result="$(ssh_w "$nip" "curl -s --max-time 5 http://$vip/" 2>&1 || true)"
      fi
      local first_line
      first_line="$(echo "$result" | head -1)"
      if [[ -n "$first_line" ]] && ! echo "$first_line" | grep -qiE "error|timed out|refused|connection"; then
        success "  $svc @ $vip  -> $first_line"
      else
        warn "  $svc @ $vip  -> FAILED ($first_line)"
      fi
    done <<< "$vips"
  done
  pause
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
summary() {
  section "Migration complete"
  cat >&2 <<EOF

  ${BOLD}Architecture${NC}
    Each node peers single-hop eBGP with its directly-attached leaf SVI
    (AS 652xx <-> AS $FABRIC_ASN). Leaves receive VIP /32s into VRF
    tenant-1 and re-originate as EVPN type-5. Every leaf sees every VIP
    with up to 4-way ECMP thanks to 'maximum-paths ibgp 4'.

  ${BOLD}Namespace exclusion${NC}
    Pool serviceSelector NotIn [kube-system, kube-public]. Services in
    those namespaces cannot get a VIP from "$POOL_NAME".

  ${BOLD}Adding another VIP pool later${NC}
    1) kubectl apply a new CiliumLoadBalancerIPPool with the same
       serviceSelector pattern and its own CIDR block.
    2) On each leaf:
         ip prefix-list K8S-VIP-POOL seq 20 permit <new-cidr> le 32
    No ClusterConfig / advertisement changes needed.

  ${BOLD}Artifacts${NC}
    $LAB_DIR/
      fabric/host-bgp.cfg            (paste on each leaf)
      manifests/                     (all applied YAML)

  ${BOLD}Cluster-side inspection${NC}
    kubectl get ciliumloadbalancerippool,ciliumbgpclusterconfig
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bgp peers
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- \\
        cilium-dbg bgp routes advertised ipv4 unicast

  ${BOLD}Fabric-side inspection (on any leaf)${NC}
    show ip bgp summary vrf tenant-1
    show ip bgp vrf tenant-1 $VIP_POOL_CIDR
    show bgp l2vpn evpn | include 192.168.100
    show ip route vrf tenant-1 $VIP_POOL_CIDR

    On a leaf whose attached host did NOT originate a given VIP, expect
    3 EVPN type-5 paths via the other VTEPs. On the originating leaf,
    expect 1 eBGP path (to the host) + 3 EVPN type-5 paths. With
    maximum-paths ibgp 4 all four are installed.

  ${BOLD}Revert${NC}
    $(basename "$0") --cleanup

EOF
}

# -----------------------------------------------------------------------------
# Cleanup: revert to original full-mesh node-to-node BGP
# -----------------------------------------------------------------------------
do_cleanup() {
  section "Cleanup: revert to original node-to-node full-mesh BGP"

  mkdir -p "$MANIFESTS_DIR"

  # Original pool (no serviceSelector)
  cat > "$MANIFESTS_DIR/lb-pool-original.yaml" <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: $POOL_NAME
spec:
  blocks:
  - cidr: $VIP_POOL_CIDR
EOF

  # Original peer config (ebgpMultihop 10)
  cat > "$MANIFESTS_DIR/bgp-peer-config-original.yaml" <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeerConfig
metadata:
  name: cluster-peer
spec:
  ebgpMultihop: 10
  timers:
    holdTimeSeconds: 30
    keepAliveTimeSeconds: 10
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: bgp
EOF

  # Original advertisement (required bgp-announce=true)
  cat > "$MANIFESTS_DIR/bgp-advertisement-original.yaml" <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPAdvertisement
metadata:
  name: lb-vip-advertisement
  labels:
    advertise: bgp
spec:
  advertisements:
  - advertisementType: Service
    service:
      addresses:
      - LoadBalancerIP
    selector:
      matchLabels:
        bgp-announce: "true"
EOF

  # Original ClusterConfigs: full-mesh (each node peers with the other 3)
  local out="$MANIFESTS_DIR/bgp-cluster-configs-original.yaml"
  : > "$out"
  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" nas="$(n_asn "$n")"
    cat >> "$out" <<EOF
---
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPClusterConfig
metadata:
  name: bgp-$nname
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: $nname
  bgpInstances:
  - name: instance-$nname
    localASN: $nas
    localPort: 179
    peers:
EOF
    for p in "${NODES[@]}"; do
      local pname="$(n_name "$p")" pip="$(n_ip "$p")" pas="$(n_asn "$p")"
      [[ "$pname" == "$nname" ]] && continue
      cat >> "$out" <<EOF
    - name: peer-$pname
      peerASN: $pas
      peerAddress: $pip
      peerConfigRef:
        name: cluster-peer
EOF
    done
  done

  for f in lb-pool-original.yaml bgp-peer-config-original.yaml \
           bgp-advertisement-original.yaml bgp-cluster-configs-original.yaml; do
    info "kubectl apply -f $f"
    kubectl apply -f "$MANIFESTS_DIR/$f" 2>&1 | sed 's/^/  /' >&2
  done
  success "Cluster-side revert complete"

  step "Fabric-side cleanup (manual, on each leaf)"
  cat >&2 <<EOF

  Remove the host-facing neighbor on each leaf:

    Leaf-1:  conf t
             router bgp 65000
               vrf tenant-1
                 no neighbor 10.1.1.10
    Leaf-2:  (same, no neighbor 10.1.2.10)
    Leaf-3:  (same, no neighbor 10.1.3.10)
    Leaf-4:  (same, no neighbor 10.1.4.10)

  Optional tidy-up (safe to leave in place):
    no route-map K8S-HOST-IN
    no route-map K8S-HOST-OUT
    no ip prefix-list K8S-VIP-POOL
    router bgp 65000 ; vrf tenant-1 ; address-family ipv4 unicast
      no maximum-paths ibgp 4

  Anycast gateway / EVPN / underlay are untouched.
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if [[ "$CLEANUP_ONLY" == "true" ]]; then
  do_cleanup
  exit 0
fi

main() {
  check_prereqs
  setup_dirs
  write_fabric_config
  generate_manifests
  apply_manifests
  verify_peering
  verify_advertised
  marquee_test || warn "marquee test had issues"
  summary
}

main "$@"
