#!/usr/bin/env bash
# =============================================================================
# validate_frr_bgp.sh
# -----------------------------------------------------------------------------
# End-to-end validator for the post-productionize_bgp.sh state:
#   - Cilium BGP removed (K8s CRs absent), Cilium agent dataplane-only
#   - FRR on each host handling BGP, installing 192.168.0.0/16 to kernel FIB
#   - vip-sync systemd service maintaining VIP /32s on lo
#   - netplan /16 supernet removed (kernel FIB sourced from FRR)
#   - Leaves still originating + advertising the /16 aggregate to each rack host
#
# DELIBERATELY NOT CHECKED: BFD session state.
# Virtual NX-OS (n9kv on EVE-NG/GNS3) counts BFD control packets in the
# control plane but does not forward them in the data plane — a well-known
# limitation of the virtual image. On real hardware this would work; the
# script validates BFD *config* existence at the leaf-SVI + BGP neighbor
# level but deliberately skips operational BFD state.
# =============================================================================

set -uo pipefail

# ---- config -----------------------------------------------------------------
readonly VIP_POOL_CIDR="192.168.100.0/24"
readonly VIP_SUPERNET="192.168.0.0/16"
readonly SW_USER="${SW_USER:-admin}"
readonly SW_PASS="${SW_PASS:-admin}"
readonly SSH_USER="${SSH_USER:-user}"
readonly LOG_FILE="$(pwd)/validate-frr-bgp-$(date +%Y%m%d-%H%M%S).log"

readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes"
readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"

# name:host-ip:leaf-svi:host-AS:vlan
readonly NODES=(
  "master:10.1.1.10:10.1.1.1:65201:11"
  "worker-1:10.1.2.10:10.1.2.1:65202:12"
  "worker-2:10.1.3.10:10.1.3.1:65203:13"
  "worker-3:10.1.4.10:10.1.4.1:65204:14"
)

# Log everything to file + stdout
exec > >(tee -a "$LOG_FILE") 2>&1

# ---- counters ---------------------------------------------------------------
PASS=0 ; FAIL=0
OUT=""
LEAF_BATCH_RAW=""

# ---- display ---------------------------------------------------------------
BOLD=$'\033[1m'; NC=$'\033[0m'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'

banner()  { printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n  %s%s%s\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" \
              "$BOLD$MAGENTA" "$NC" "$BOLD$MAGENTA" "$*" "$NC" "$BOLD$MAGENTA" "$NC"; }
info()    { printf "%s[i]%s %s\n"  "$BLUE"   "$NC" "$*"; }
ok()      { printf "   %s✓%s %s\n" "$GREEN"  "$NC" "$*"; PASS=$((PASS+1)); }
nok()     { printf "   %s✗%s %s\n" "$RED"    "$NC" "$*"; FAIL=$((FAIL+1)); }

check() {
  local label="$1" ; shift
  if eval "$@" >/dev/null 2>&1; then ok "$label"; else nok "$label"; fi
}

run_cmd() {
  local label="$1" disp="$2" cmd="$3"
  printf "\n%s── %s%s\n"       "$BOLD$BLUE" "$label" "$NC"
  printf "   $ %s\n"          "$disp"
  OUT="$(eval "$cmd" 2>&1)" || true
  printf "   ┄┄┄ raw output ┄┄┄\n"
  echo "$OUT" | sed 's/^/       /'
  printf "   ┄┄┄\n"
}

show_cmd_output() {
  local label="$1" disp="$2" out="$3"
  printf "\n%s── %s%s\n"       "$BOLD$BLUE" "$label" "$NC"
  printf "   $ %s\n"          "$disp"
  printf "   ┄┄┄ raw output ┄┄┄\n"
  echo "$out" | sed 's/^/       /'
  printf "   ┄┄┄\n"
  OUT="$out"
}

# ---- field extractors -------------------------------------------------------
n_name(){ echo "$1" | cut -d: -f1; }
n_ip()  { echo "$1" | cut -d: -f2; }
n_svi() { echo "$1" | cut -d: -f3; }
n_as()  { echo "$1" | cut -d: -f4; }
n_vlan(){ echo "$1" | cut -d: -f5; }

ssh_h() { ssh $SSH_OPTS "$SSH_USER@$1" "$2" 2>&1; }

# ---- NX-OS batched SSH ------------------------------------------------------
nxos_batch_run() {
  local svi="$1"; shift
  local cmds=("$@")
  local input="terminal length 0"$'\n'
  for c in "${cmds[@]}"; do
    input+="show clock"$'\n'"$c"$'\n'
  done
  input+="exit"$'\n'
  LEAF_BATCH_RAW=$(timeout 45 sshpass -p "$SW_PASS" \
                   ssh -T $SSH_OPTS_NXOS "$SW_USER@$svi" <<<"$input" 2>&1 || true)
}

nxos_batch_section() {
  local idx="$1"
  echo "$LEAF_BATCH_RAW" | awk -v n="$idx" '
    /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+[[:space:]]+[A-Z]+/ { c++; next }
    c==n+1 { print }
  '
}

# =============================================================================
# Prereq
# =============================================================================
section_prereq() {
  banner "Prerequisites"
  check "sshpass available"                    "command -v sshpass"
  check "kubectl reachable"                    "kubectl get nodes >/dev/null"
  check "sshpass + ssh to Leaf-1 (10.1.1.1)"  \
        "timeout 10 sshpass -p '$SW_PASS' ssh $SSH_OPTS_NXOS '$SW_USER@10.1.1.1' 'show clock' >/dev/null"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    check "ssh to $nm ($ip) works" "ssh_h '$ip' 'hostname' >/dev/null"
  done
}

# =============================================================================
# Section 1 - Cluster layer
# =============================================================================
section_cluster() {
  banner "1. Cluster layer (K8s + Cilium absent + vip-sync RBAC + LB services)"

  run_cmd "1.1 kubernetes nodes" \
          "kubectl get nodes -o wide" \
          "kubectl get nodes -o wide"
  local ready
  ready=$(echo "$OUT" | awk 'NR>1 && $2=="Ready"' | wc -l)
  [[ "$ready" -ge 4 ]] && ok "$ready/4 nodes Ready" || nok "only $ready/4 Ready"

  run_cmd "1.2 Cilium daemonset (dataplane only)" \
          "kubectl -n kube-system get ds cilium" \
          "kubectl -n kube-system get ds cilium"
  check "Cilium DS present" "echo \"\$OUT\" | grep -q '^cilium'"

  run_cmd "1.3 Cilium BGP CRs REMOVED" \
          "kubectl get ciliumbgpclusterconfig,ciliumbgppeerconfig,ciliumbgpadvertisement --ignore-not-found -o name" \
          "kubectl get ciliumbgpclusterconfig,ciliumbgppeerconfig,ciliumbgpadvertisement --ignore-not-found -o name"
  local cr_count
  cr_count=$(echo "$OUT" | grep -cv '^$' || true)
  [[ "$cr_count" -eq 0 ]] && ok "zero Cilium BGP CRs (cleanly torn down)" \
                           || nok "$cr_count Cilium BGP CRs still present"

  run_cmd "1.4 vip-sync ServiceAccount" \
          "kubectl -n kube-system get sa vip-sync" \
          "kubectl -n kube-system get sa vip-sync"
  check "vip-sync SA exists" "echo \"\$OUT\" | grep -q '^vip-sync'"

  run_cmd "1.5 vip-sync RBAC" \
          "kubectl get clusterrole vip-sync-reader clusterrolebinding vip-sync-binding" \
          "kubectl get clusterrole vip-sync-reader clusterrolebinding vip-sync-binding"
  check "vip-sync ClusterRole + Binding exist" \
        "echo \"\$OUT\" | grep -q 'vip-sync-reader' && echo \"\$OUT\" | grep -q 'vip-sync-binding'"

  run_cmd "1.6 LoadBalancer services (excluding system namespaces)" \
          "kubectl get svc -A --field-selector spec.type=LoadBalancer" \
          "kubectl get svc -A --field-selector spec.type=LoadBalancer"
  local lb_count lb_sys
  lb_count=$(echo "$OUT" | awk 'NR>1 && $1 != "kube-system" && $1 != "kube-public"' | wc -l)
  lb_sys=$(  echo "$OUT" | awk 'NR>1 && ($1 == "kube-system" || $1 == "kube-public")' | wc -l)
  [[ "$lb_count" -ge 1 ]] && ok "$lb_count LB services in non-system namespaces" \
                          || nok "no LB services in user namespaces"
  [[ "$lb_sys"   -eq 0 ]] && ok "no LB services in kube-system / kube-public" \
                          || nok "$lb_sys LB services in system namespaces"
  check "VIPs from $VIP_POOL_CIDR" \
        "echo \"\$OUT\" | grep -qE '192\\.168\\.100\\.[0-9]+'"
}

# =============================================================================
# Section 2 - FRR + vip-sync per node
# =============================================================================
section_frr_per_node() {
  banner "2. FRR + vip-sync per node (services, BGP, advertised/received, VIPs on lo)"

  # Count desired VIPs from K8s (excluding system namespaces)
  local expected_vips
  expected_vips=$(kubectl get svc -A --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[?(@.metadata.namespace!="kube-system")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    | grep -v '^$' | wc -l)
  info "expected VIPs from K8s = $expected_vips"

  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n") leaf=$(n_svi "$n") as=$(n_as "$n")

    # 2.X.1 vip-sync active
    run_cmd "2.$nm vip-sync service state" \
            "[$nm] systemctl is-active vip-sync" \
            "ssh_h '$ip' 'systemctl is-active vip-sync'"
    check "$nm: vip-sync active"  "echo \"\$OUT\" | tail -1 | grep -qx 'active'"

    # 2.X.2 frr active
    run_cmd "2.$nm FRR service state" \
            "[$nm] systemctl is-active frr" \
            "ssh_h '$ip' 'systemctl is-active frr'"
    check "$nm: frr active"  "echo \"\$OUT\" | tail -1 | grep -qx 'active'"

    # 2.X.3 daemons file has bgpd=yes and bfdd=yes
    run_cmd "2.$nm FRR daemons enabled" \
            "[$nm] grep -E '^(bgpd|bfdd)=' /etc/frr/daemons" \
            "ssh_h '$ip' 'sudo grep -E \"^(bgpd|bfdd)=\" /etc/frr/daemons'"
    check "$nm: bgpd=yes"  "echo \"\$OUT\" | grep -qx 'bgpd=yes'"
    check "$nm: bfdd=yes"  "echo \"\$OUT\" | grep -qx 'bfdd=yes'"

    # 2.X.4 BGP session Established with leaf
    run_cmd "2.$nm FRR show bgp summary" \
            "[$nm] sudo vtysh -c 'show bgp summary'" \
            "ssh_h '$ip' 'sudo vtysh -c \"show bgp summary\"'"
    check "$nm: session to $leaf up (PfxRcd numeric)" \
          "echo \"\$OUT\" | awk -v p='$leaf' '\$1==p {print \$10}' | grep -Eq '^[0-9]+\$'"
    check "$nm: peer AS = 65000" \
          "echo \"\$OUT\" | awk -v p='$leaf' '\$1==p {print \$3}' | grep -qx '65000'"
    check "$nm: local AS = $as" \
          "echo \"\$OUT\" | grep -q 'local AS number $as'"
    check "$nm: PfxRcd >= 1 (supernet from leaf)" \
          "[[ \"\$(echo \"\$OUT\" | awk -v p='$leaf' '\$1==p {print \$10}')\" -ge 1 ]]"

    # 2.X.5 Supernet is in local BGP RIB (came from leaf)
    # NOTE: we avoid 'neighbor X received-routes' because it requires
    # 'soft-reconfiguration inbound', which we don't enable on FRR.
    # 'show ip bgp PREFIX' queries the BGP table post-policy, which is
    # equivalent for our purpose (we want to confirm the supernet got
    # accepted and installed).
    run_cmd "2.$nm FRR BGP RIB entry for supernet" \
            "[$nm] sudo vtysh -c 'show ip bgp $VIP_SUPERNET'" \
            "ssh_h '$ip' 'sudo vtysh -c \"show ip bgp $VIP_SUPERNET\"'"
    check "$nm: supernet $VIP_SUPERNET in BGP table" \
          "echo \"\$OUT\" | grep -qE 'BGP routing table entry for $VIP_SUPERNET'"
    check "$nm: supernet received from $leaf (peer AS 65000)" \
          "echo \"\$OUT\" | grep -qE 'from $leaf'"

    # 2.X.6 Advertised routes include the VIP /32s
    run_cmd "2.$nm FRR advertised routes" \
            "[$nm] sudo vtysh -c 'show bgp ipv4 unicast neighbor $leaf advertised-routes'" \
            "ssh_h '$ip' 'sudo vtysh -c \"show bgp ipv4 unicast neighbor $leaf advertised-routes\"'"
    local adv_cnt
    adv_cnt=$(echo "$OUT" | grep -cE '192\.168\.100\.[0-9]+/32' || true)
    [[ "$adv_cnt" -ge 1 ]] && ok "$nm: advertising $adv_cnt VIP /32(s) to leaf" \
                           || nok "$nm: advertising 0 VIP /32s"

    # 2.X.7 VIPs present on lo (vip-sync is actually doing its job)
    run_cmd "2.$nm vip-sync state (lo /32s)" \
            "[$nm] ip -4 addr show dev lo" \
            "ssh_h '$ip' 'ip -4 addr show dev lo'"
    local lo_count
    lo_count=$(echo "$OUT" | grep -cE 'inet 192\.168\.[0-9]+\.[0-9]+/32' || true)
    if [[ "$lo_count" -eq "$expected_vips" ]]; then
      ok "$nm: $lo_count/$expected_vips VIP(s) on lo (matches cluster state)"
    elif [[ "$lo_count" -ge 1 ]]; then
      nok "$nm: $lo_count/$expected_vips VIPs on lo (mismatch — vip-sync lag?)"
    else
      nok "$nm: no VIPs on lo — vip-sync not working"
    fi
  done
}

# =============================================================================
# Section 3 - Host kernel FIB (FRR installed, netplan static gone)
# =============================================================================
section_host_kernel() {
  banner "3. Host kernel FIB (proto bgp from FRR, no netplan /16 static)"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n") leaf=$(n_svi "$n")

    run_cmd "3.$nm ip route show $VIP_SUPERNET" \
            "[$nm] ip route show $VIP_SUPERNET" \
            "ssh_h '$ip' 'ip route show $VIP_SUPERNET'"
    check "$nm: $VIP_SUPERNET proto bgp (installed by FRR)" \
          "echo \"\$OUT\" | grep -q 'proto bgp'"
    check "$nm: $VIP_SUPERNET NOT proto static (netplan dropped)" \
          "! echo \"\$OUT\" | grep -q 'proto static'"
    check "$nm: next-hop is leaf SVI $leaf" \
          "echo \"\$OUT\" | grep -q 'via $leaf'"

    # Probe a non-VIP address inside the supernet. We can't use an actual
    # VIP here — vip-sync puts VIPs on lo, which makes 'ip route get <vip>'
    # return the LOCAL routing table (correct for self-delivery). To verify
    # the BGP-installed supernet path works, we use an unassigned address
    # in 192.168.0.0/16 that definitively does NOT live on lo.
    local probe_ip="192.168.200.1"
    run_cmd "3.$nm ip route get $probe_ip (non-VIP probe in supernet)" \
            "[$nm] ip route get $probe_ip" \
            "ssh_h '$ip' 'ip route get $probe_ip'"
    check "$nm: non-VIP supernet address resolves via $leaf dev ens4" \
          "echo \"\$OUT\" | grep -q 'via $leaf dev ens4'"
  done
}

# =============================================================================
# Section 4 - VIP reachability (curl matrix)
# =============================================================================
section_reachability() {
  banner "4. VIP reachability (curl each VIP from every node)"

  local vips
  vips="$(kubectl get svc -A --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    | grep -v '=$' | grep -vE '^(kube-system|kube-public)/' || true)"

  if [[ -z "$vips" ]]; then nok "no VIPs to test"; return; fi

  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    while IFS='=' read -r svc vip; do
      [[ -z "$vip" ]] && continue
      run_cmd "4.$nm -> $svc @ $vip" \
              "[$nm] curl -s --max-time 5 http://$vip/" \
              "ssh_h '$ip' 'curl -s --max-time 5 http://$vip/'"
      [[ -n "$OUT" ]] && ok "$nm: got response \"${OUT:0:80}\"" \
                      || nok "$nm: no response from $vip"
    done <<<"$vips"
  done
}

# =============================================================================
# Section 5 - Fabric (NX-OS leaves)
# =============================================================================
section_fabric() {
  banner "5. Fabric (NX-OS leaves) - BGP VRF + RIB + EVPN + /16 aggregate"
  info "BFD OPERATIONAL STATE NOT CHECKED (virtual NX-OS / n9kv limitation)"
  info "BFD config presence IS checked at the SVI + neighbor level."

  local cmds=(
    "show bgp ipv4 unicast summary vrf tenant-1"    # 0
    "show ip bgp vrf tenant-1"                      # 1
    "show ip route 192.168.100.0 vrf tenant-1"      # 2
    "show ip route 192.168.100.1 vrf tenant-1"      # 3
    "show ip route 192.168.100.2 vrf tenant-1"      # 4
    "show ip route 192.168.100.3 vrf tenant-1"      # 5
    "show bgp l2vpn evpn | include 192.168.100"     # 6
    "show running-config bgp"                        # 7
    "show ip bgp vrf tenant-1 $VIP_SUPERNET"        # 8
    "show running-config interface"                  # 9  (for BFD config check)
  )

  for n in "${NODES[@]}"; do
    local lname="Leaf-${n:(-2):1}"  # cheap: use vlan suffix
    lname="Leaf-$(n_vlan "$n" | sed 's/^1//')"  # Vlan11 -> Leaf-1, Vlan12 -> Leaf-2, etc.
    local svi=$(n_svi "$n") hip=$(n_ip "$n") has=$(n_as "$n") hnm=$(n_name "$n") vlan=$(n_vlan "$n")

    printf "\n%s────────── %s (SVI %s, peer %s/%s) ──────────%s\n" \
           "$BOLD$BLUE" "$lname" "$svi" "$hnm" "$has" "$NC"
    printf "%s[i]%s running %d show commands in a single SSH session\n" \
           "$BLUE" "$NC" "${#cmds[@]}"

    nxos_batch_run "$svi" "${cmds[@]}"
    if [[ -z "$LEAF_BATCH_RAW" ]]; then
      nok "$lname: batched SSH returned no output"
      continue
    fi

    # 5.1 BGP summary
    show_cmd_output "5.$lname.1 show bgp ipv4 unicast summary vrf tenant-1" \
                    "ssh admin@$svi 'show bgp ipv4 unicast summary vrf tenant-1'" \
                    "$(nxos_batch_section 0)"
    check "$lname: neighbor $hip present"  "echo \"\$OUT\" | grep -q '$hip'"
    check "$lname: neighbor AS=$has"       "echo \"\$OUT\" | awk -v ip='$hip' '\$1==ip' | grep -q '$has'"
    check "$lname: session Established (PfxRcd numeric)" \
          "echo \"\$OUT\" | awk -v ip='$hip' '\$1==ip {print \$NF}' | grep -Eq '^[0-9]+\$'"
    check "$lname: PfxRcd >= 1 from host (FRR advertising VIPs)" \
          "[[ \"\$(echo \"\$OUT\" | awk -v ip='$hip' '\$1==ip {print \$NF}')\" -ge 1 ]]"

    # 5.2 BGP table
    show_cmd_output "5.$lname.2 show ip bgp vrf tenant-1" \
                    "ssh admin@$svi 'show ip bgp vrf tenant-1'" \
                    "$(nxos_batch_section 1)"
    local vip32_count
    vip32_count=$(echo "$OUT" | grep -cE '192\.168\.100\.[0-9]+/32' || true)
    [[ "$vip32_count" -ge 4 ]] \
      && ok "$lname: $vip32_count VIP /32(s) in BGP table (expected >= 4)" \
      || nok "$lname: only $vip32_count VIP /32s (expected >= 4)"
    check "$lname: local eBGP path present (*>e via host)" \
          "echo \"\$OUT\" | grep -Eq '\\*>e.*$hip'"

    # 5.3 FIB per /32
    for octet in 0 1 2 3; do
      local vip="192.168.100.$octet"
      local sidx=$((2 + octet))
      show_cmd_output "5.$lname.3.$octet show ip route $vip vrf tenant-1" \
                      "ssh admin@$svi 'show ip route $vip vrf tenant-1'" \
                      "$(nxos_batch_section $sidx)"
      check "$lname: $vip/32 next-hop $hip (local host)" \
            "echo \"\$OUT\" | grep -Eq 'via $hip'"
      check "$lname: $vip/32 bgp-65000 external" \
            "echo \"\$OUT\" | grep -q 'bgp-65000, external'"
    done

    # 5.4 EVPN type-5
    # We check that VIPs ARE visible in the EVPN table. We deliberately do
    # NOT check whether the leaf shows them as *>l (locally-originated) —
    # that marker is inconsistent across NX-OS 10.5 runs when 'advertise-pip'
    # is in use and paths from multiple VTEPs exist for the same /32.
    # Leaf-local origination is already proven by section 5.2's "*>e via host"
    # (eBGP from the directly-attached FRR) and the supernet advertisement
    # to the host in 5.6. This check is purely about the type-5 plumbing
    # reaching this leaf from its EVPN peers.
    show_cmd_output "5.$lname.4 show bgp l2vpn evpn | include 192.168.100" \
                    "ssh admin@$svi 'show bgp l2vpn evpn | include 192.168.100'" \
                    "$(nxos_batch_section 6)"
    local vip_evpn_count
    vip_evpn_count=$(echo "$OUT" | grep -cE '\[5\]:\[0\]:\[0\]:\[32\]:\[192\.168\.100\.[0-9]+\]' || true)
    [[ "$vip_evpn_count" -ge 4 ]] \
      && ok "$lname: $vip_evpn_count type-5 EVPN entries for VIP /32s (expected >= 4)" \
      || nok "$lname: only $vip_evpn_count type-5 EVPN entries for VIP /32s"
    check "$lname: imports type-5 VIPs from peer VTEPs (* i)" \
          "echo \"\$OUT\" | grep -Eq '\\* i\\[5\\]:\\[0\\]:\\[0\\]:\\[32\\]:\\[192\\.168\\.100\\.'"

    # 5.5 Running-config BGP
    show_cmd_output "5.$lname.5 show running-config bgp" \
                    "ssh admin@$svi 'show running-config bgp'" \
                    "$(nxos_batch_section 7)"
    check "$lname: VRF tenant-1 present"             "echo \"\$OUT\" | grep -q 'vrf tenant-1'"
    check "$lname: neighbor $hip configured"         "echo \"\$OUT\" | grep -q 'neighbor $hip'"
    check "$lname: K8S-HOST-IN route-map inbound"    "echo \"\$OUT\" | grep -q 'route-map K8S-HOST-IN in'"
    check "$lname: K8S-HOST-OUT route-map outbound"  "echo \"\$OUT\" | grep -q 'route-map K8S-HOST-OUT out'"
    check "$lname: aggregate-address $VIP_SUPERNET"  "echo \"\$OUT\" | grep -q 'aggregate-address $VIP_SUPERNET'"
    check "$lname: BFD CONFIGURED on neighbor (operational state not checked)" \
          "echo \"\$OUT\" | awk '/neighbor $hip/,/^  [^ ]/' | grep -q 'bfd'"

    # 5.6 Supernet aggregate best path + advertised-to-host
    show_cmd_output "5.$lname.6 show ip bgp vrf tenant-1 $VIP_SUPERNET" \
                    "ssh admin@$svi 'show ip bgp vrf tenant-1 $VIP_SUPERNET'" \
                    "$(nxos_batch_section 8)"
    check "$lname: $VIP_SUPERNET in BGP RIB" \
          "echo \"\$OUT\" | grep -q 'BGP routing table entry for $VIP_SUPERNET'"
    check "$lname: $VIP_SUPERNET is locally-originated aggregate best path" \
          "echo \"\$OUT\" | grep -Eq 'Path type: aggregate.*is best path'"
    check "$lname: $VIP_SUPERNET advertised to $hip" \
          "echo \"\$OUT\" | awk '/Path-id.*advertised to peers:/,0' | grep -q '$hip'"

    # 5.7 Interface BFD config (bfd interval present on SVI) — config only
    show_cmd_output "5.$lname.7 show running-config interface Vlan$vlan" \
                    "ssh admin@$svi 'show running-config interface Vlan$vlan'" \
                    "$(nxos_batch_section 9)"
    check "$lname: Vlan$vlan has 'bfd interval' configured (state NOT checked)" \
          "echo \"\$OUT\" | grep -q 'bfd interval'"
    check "$lname: Vlan$vlan has 'no ip redirects' (required for BFD on real HW)" \
          "echo \"\$OUT\" | grep -q 'no ip redirects'"
  done
}

# =============================================================================
# Summary
# =============================================================================
summary() {
  banner "Summary"
  local total=$((PASS+FAIL))
  printf "   Passed: %s%d / %d%s\n" "$BOLD$GREEN" "$PASS"  "$total" "$NC"
  printf "   Failed: %s%d / %d%s\n" "$BOLD$RED"   "$FAIL" "$total" "$NC"
  printf "   Transcript: %s\n"                              "$LOG_FILE"
  echo
  if [[ "$FAIL" -eq 0 ]]; then
    printf "  %sALL CHECKS PASSED%s\n" "$BOLD$GREEN" "$NC"
    printf "  %s(BFD operational state intentionally skipped — virtual NX-OS limitation)%s\n" \
           "$YELLOW" "$NC"
  else
    printf "  %sSOME CHECKS FAILED — review the ✗ lines above%s\n" "$BOLD$RED" "$NC"
  fi
}

# =============================================================================
# Main
# =============================================================================
main() {
  printf "Validation run: %s\n"          "$(date -Iseconds)"
  printf "Log: %s\n"                     "$LOG_FILE"
  section_prereq
  [[ "$FAIL" -gt 0 ]] && { summary; return 1; }

  section_cluster
  section_frr_per_node
  section_host_kernel
  section_reachability
  section_fabric
  summary
  [[ "$FAIL" -eq 0 ]]
}

main "$@"
