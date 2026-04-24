#!/usr/bin/env bash
# =============================================================================
# validate_leaf_bgp.sh
# -----------------------------------------------------------------------------
# End-to-end validation of the node-to-leaf BGP + EVPN-VXLAN VIP design.
# Run from master. SSH into workers (key auth) and leaves (admin/admin via
# sshpass). For every check: shows the command, prints the raw output
# verbatim, then lists the pass/fail assessments derived from that output.
# A full transcript is tee'd to $LOG_FILE for later review.
# =============================================================================
set -uo pipefail    # NB: no -e; we want all checks to run even after failures

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
readonly SSH_USER="${SSH_USER:-user}"
readonly LEAF_USER="${LEAF_USER:-admin}"
readonly LEAF_PASS="${LEAF_PASS:-admin}"

readonly SSH_OPTS_LINUX="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -n"
readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"

# node-name : ens4-ip : local-asn : leaf-svi
readonly NODES=(
  "master:10.1.1.10:65201:10.1.1.1"
  "worker-1:10.1.2.10:65202:10.1.2.1"
  "worker-2:10.1.3.10:65203:10.1.3.1"
  "worker-3:10.1.4.10:65204:10.1.4.1"
)

# leaf-name : svi : peer-host-ip : peer-host-asn : peer-host-name
readonly LEAVES=(
  "Leaf-1:10.1.1.1:10.1.1.10:65201:master"
  "Leaf-2:10.1.2.1:10.1.2.10:65202:worker-1"
  "Leaf-3:10.1.3.1:10.1.3.10:65203:worker-2"
  "Leaf-4:10.1.4.1:10.1.4.10:65204:worker-3"
)

readonly VIP_CIDR="192.168.100.0/24"
readonly SUPERNET="192.168.0.0/16"
readonly LOG_FILE="$(pwd)/validate-leaf-bgp-$(date +%Y%m%d-%H%M%S).log"
readonly CMD_TIMEOUT=30     # hard cap on any single command (kills hangs)

# -----------------------------------------------------------------------------
# Mirror all output to a log file
# -----------------------------------------------------------------------------
exec > >(tee -a "$LOG_FILE") 2>&1

# -----------------------------------------------------------------------------
# Display helpers
# -----------------------------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'

PASS=0; FAIL=0

banner() {
  printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$BOLD$MAGENTA" "$NC"
  printf "%s  %s%s\n" "$BOLD$MAGENTA" "$*" "$NC"
  printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$BOLD$MAGENTA" "$NC"
}

# run_cmd  "description"  "what to display as the command"  "actual bash to execute"
# Populates $OUT with raw output. Shows command, shows raw output, then
# the caller prints pass/fail assertions based on $OUT.
OUT=""
run_cmd() {
  local desc="$1" display="$2" cmd="$3"
  printf "\n%s── %s%s\n"   "$BOLD$CYAN" "$desc"    "$NC"
  printf "%s   $ %s%s\n"   "$YELLOW"    "$display" "$NC"
  printf "%s   ┄┄┄ raw output ┄┄┄%s\n"  "$DIM"     "$NC"
  OUT="$(timeout "$CMD_TIMEOUT" bash -c "$cmd" 2>&1)" || true
  if [[ -z "$OUT" ]]; then
    printf "   %s(no output / timeout)%s\n" "$DIM" "$NC"
  else
    echo "$OUT" | sed 's/^/       /'
  fi
  printf "%s   ┄┄┄%s\n" "$DIM" "$NC"
}

# Same visual shape as run_cmd, but for output we already captured.
# Used to display slices of a batched NX-OS SSH session.
show_cmd_output() {
  local desc="$1" display="$2" output="$3"
  printf "\n%s── %s%s\n"   "$BOLD$CYAN" "$desc"    "$NC"
  printf "%s   $ %s%s\n"   "$YELLOW"    "$display" "$NC"
  printf "%s   ┄┄┄ raw output ┄┄┄%s\n"  "$DIM"     "$NC"
  if [[ -z "$output" ]]; then
    printf "   %s(no output)%s\n" "$DIM" "$NC"
  else
    echo "$output" | sed 's/^/       /'
  fi
  printf "%s   ┄┄┄%s\n" "$DIM" "$NC"
  OUT="$output"
}

# -----------------------------------------------------------------------------
# NX-OS batched execution
# -----------------------------------------------------------------------------
# A fresh sshpass/password auth per show command trips the NX-OS SSH
# server's throttle around the 3rd-4th rapid connect from the same src.
# Solution: run ALL commands for a leaf in ONE SSH session, separated
# by `show clock` markers so we can split the output back into per-command
# chunks for display.

LEAF_BATCH_RAW=""

# nxos_batch_run  <leaf-svi>  <cmd1> [cmd2 ...]
# Populates LEAF_BATCH_RAW with the combined output.
nxos_batch_run() {
  local svi="$1"; shift
  local cmds=("$@")

  local input="terminal length 0"$'\n'
  local c
  for c in "${cmds[@]}"; do
    input+="show clock"$'\n'
    input+="${c}"$'\n'
  done
  input+="show clock"$'\n'
  input+="exit"$'\n'

  LEAF_BATCH_RAW="$(timeout "$CMD_TIMEOUT" \
    sshpass -p "$LEAF_PASS" ssh -T $SSH_OPTS_NXOS \
    "$LEAF_USER@$svi" <<<"$input" 2>&1)" || true
}

# nxos_batch_section <index>
# Extracts the Nth command's output from LEAF_BATCH_RAW to stdout.
# Sections are delimited by the time-of-day line from `show clock`.
nxos_batch_section() {
  local idx="$1"
  echo "$LEAF_BATCH_RAW" | awk -v target="$idx" '
    BEGIN { section = -1 }
    # "HH:MM:SS.mmm TZ Day Mon DD YYYY" — the show-clock time line
    /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+[[:space:]]+[A-Z]+/ { section++; next }
    /^Time source is/ { next }
    /^terminal length 0/ { next }
    { if (section == target) print }
  '
}

ok()    { printf "   %s✓%s %s\n" "$GREEN" "$NC" "$*"; PASS=$((PASS+1)); }
nok()   { printf "   %s✗%s %s\n" "$RED"   "$NC" "$*"; FAIL=$((FAIL+1)); }
check() {
  # check "assertion message" <command that returns 0/1>
  local msg="$1"; shift
  if eval "$@" >/dev/null 2>&1; then ok "$msg"; else nok "$msg"; fi
}

# -----------------------------------------------------------------------------
# Record-field helpers
# -----------------------------------------------------------------------------
n_name() { echo "$1" | cut -d: -f1; }
n_ip()   { echo "$1" | cut -d: -f2; }
n_asn()  { echo "$1" | cut -d: -f3; }
n_leaf() { echo "$1" | cut -d: -f4; }

l_name()    { echo "$1" | cut -d: -f1; }
l_svi()     { echo "$1" | cut -d: -f2; }
l_host_ip() { echo "$1" | cut -d: -f3; }
l_host_as() { echo "$1" | cut -d: -f4; }
l_host_nm() { echo "$1" | cut -d: -f5; }

# -----------------------------------------------------------------------------
# SSH helpers
# -----------------------------------------------------------------------------
# Run a command on a node. Master = local; workers = ssh.
node_run() {
  local nname="$1" nip="$2" cmd="$3"
  if [[ "$nname" == "master" ]]; then
    bash -c "$cmd" 2>&1
  else
    ssh $SSH_OPTS_LINUX "$SSH_USER@$nip" "$cmd" 2>&1
  fi
}

# Runnable strings suitable for passing to eval. They include quoting
# so that run_cmd can show and execute in one go.
node_cmd_str() {
  local nname="$1" nip="$2" cmd="$3"
  if [[ "$nname" == "master" ]]; then
    printf '%s' "$cmd"
  else
    # SSH with the command quoted
    printf "ssh %s '%s@%s' %q" "$SSH_OPTS_LINUX" "$SSH_USER" "$nip" "$cmd"
  fi
}

# Cilium agent pod on a given node
cilium_pod_on() {
  kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Prerequisite check
# -----------------------------------------------------------------------------
check_prereqs() {
  banner "Prerequisites"

  if ! command -v sshpass >/dev/null 2>&1; then
    printf "%s[!]%s sshpass not installed — installing via apt\n" "$YELLOW" "$NC"
    sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
  fi
  check "sshpass available"  "command -v sshpass"
  check "kubectl reachable"  "kubectl get nodes"
  check "sshpass + ssh to Leaf-1 works" \
        "sshpass -p '$LEAF_PASS' ssh $SSH_OPTS_NXOS $LEAF_USER@10.1.1.1 'show hostname | no-more'"
  for w in worker-1 worker-2 worker-3; do
    local wip
    for n in "${NODES[@]}"; do [[ "$(n_name "$n")" == "$w" ]] && wip="$(n_ip "$n")"; done
    check "ssh to $w ($wip) works" \
          "ssh $SSH_OPTS_LINUX $SSH_USER@$wip 'hostname'"
  done
}

# =============================================================================
# Section 1 - Cluster layer
# =============================================================================
section_cluster() {
  banner "1. Cluster layer (K8s + Cilium CRDs)"

  run_cmd "1.1 kubernetes nodes" \
          "kubectl get nodes -o wide" \
          "kubectl get nodes -o wide"
  local ready_count
  ready_count="$(echo "$OUT" | awk 'NR>1 && $2=="Ready"' | wc -l)"
  [[ "$ready_count" -eq 4 ]] && ok "4/4 nodes Ready" || nok "$ready_count/4 nodes Ready"

  run_cmd "1.2 Cilium daemonset" \
          "kubectl -n kube-system get ds cilium" \
          "kubectl -n kube-system get ds cilium"
  check "Cilium DS present" "echo \"\$OUT\" | grep -q '^cilium'"

  run_cmd "1.3 LB IP Pool (expect serviceSelector NotIn [kube-system, kube-public])" \
          "kubectl get ciliumloadbalancerippool ai-vip-pool -o yaml" \
          "kubectl get ciliumloadbalancerippool ai-vip-pool -o yaml"
  check "pool has $VIP_CIDR block"           "echo \"\$OUT\" | grep -q 'cidr: $VIP_CIDR'"
  check "pool has serviceSelector"           "echo \"\$OUT\" | grep -q 'serviceSelector:'"
  check "pool excludes kube-system"          "echo \"\$OUT\" | grep -q 'kube-system'"
  check "pool excludes kube-public"          "echo \"\$OUT\" | grep -q 'kube-public'"

  run_cmd "1.4 BGPAdvertisement (expect selector: {}) " \
          "kubectl get ciliumbgpadvertisement lb-vip-advertisement -o yaml" \
          "kubectl get ciliumbgpadvertisement lb-vip-advertisement -o yaml"
  check "advertisementType: Service"         "echo \"\$OUT\" | grep -q 'advertisementType: Service'"
  check "LoadBalancerIP address family"      "echo \"\$OUT\" | grep -q 'LoadBalancerIP'"
  check "selector present (empty = match-all)" \
        "echo \"\$OUT\" | awk '/^[[:space:]]*selector:/ {found=1; print; next} found {print; exit}' | grep -qE 'selector: *\\{\\}|matchLabels: *\\{\\}|matchExpressions: *\\[\\]'"

  run_cmd "1.5 BGPPeerConfig" \
          "kubectl get ciliumbgppeerconfig cluster-peer -o yaml" \
          "kubectl get ciliumbgppeerconfig cluster-peer -o yaml"
  check "ebgpMultihop present"               "echo \"\$OUT\" | grep -q 'ebgpMultihop:'"

  run_cmd "1.6 BGPClusterConfigs (one per node, one leaf peer each)" \
          "kubectl get ciliumbgpclusterconfig" \
          "kubectl get ciliumbgpclusterconfig"
  for n in "${NODES[@]}"; do
    check "ClusterConfig bgp-$(n_name "$n") exists" \
          "echo \"\$OUT\" | grep -q 'bgp-$(n_name "$n")'"
  done

  run_cmd "1.7 LoadBalancer services (excluding system namespaces)" \
          "kubectl get svc -A --field-selector spec.type=LoadBalancer" \
          "kubectl get svc -A --field-selector spec.type=LoadBalancer"
  local lb_count
  lb_count="$(echo "$OUT" | awk 'NR>1 && $1 != "kube-system" && $1 != "kube-public"' | wc -l)"
  [[ "$lb_count" -ge 1 ]] && ok "$lb_count LB services in non-system namespaces" \
                         || nok "no LB services found outside kube-system/kube-public"
  check "no LB services in kube-system"      "! echo \"\$OUT\" | awk 'NR>1 && \$1==\"kube-system\"' | grep -q ."
  check "no LB services in kube-public"      "! echo \"\$OUT\" | awk 'NR>1 && \$1==\"kube-public\"' | grep -q ."
  check "VIPs from 192.168.100.0/24"          "echo \"\$OUT\" | grep -q '192\\.168\\.100\\.'"
}

# =============================================================================
# Section 2 - Cilium BGP per node
# =============================================================================
section_cilium_bgp() {
  banner "2. Cilium BGP per node (session + advertised routes)"

  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" nasn="$(n_asn "$n")" leaf="$(n_leaf "$n")"
    local pod; pod="$(cilium_pod_on "$nname")"
    if [[ -z "$pod" ]]; then nok "$nname: no cilium-agent pod found"; continue; fi

    run_cmd "2.$nname BGP peer state" \
            "kubectl -n kube-system exec $pod -c cilium-agent -- cilium-dbg bgp peers" \
            "kubectl -n kube-system exec '$pod' -c cilium-agent -- cilium-dbg bgp peers"
    check "$nname: session to $leaf established" \
          "echo \"\$OUT\" | grep -E '(^|[[:space:]])$leaf(:[0-9]+)?[[:space:]]' | grep -qi established"
    check "$nname: peer ASN = 65000"          "echo \"\$OUT\" | grep -q '65000'"
    check "$nname: local ASN = $nasn"          "echo \"\$OUT\" | grep -q '$nasn'"
    # `cilium-dbg bgp peers` Received column is the authoritative counter for
    # routes ingested from the leaf. (The `routes available` table is Loc-RIB
    # origin-side only in this build, so it cannot confirm received paths.)
    check "$nname: Received >= 1 from leaf (supernet)" \
          "echo \"\$OUT\" | awk -v p='$leaf' '\$0 ~ p { for(i=1;i<=NF;i++) if(\$i==\"ipv4/unicast\") { print \$(i+1); exit } }' | awk '{ exit !(\$1>=1) }'"

    run_cmd "2.$nname routes advertised to leaf" \
            "kubectl -n kube-system exec $pod -c cilium-agent -- cilium-dbg bgp routes advertised ipv4 unicast" \
            "kubectl -n kube-system exec '$pod' -c cilium-agent -- cilium-dbg bgp routes advertised ipv4 unicast"
    local adv_count
    adv_count="$(echo "$OUT" | grep -cE '192\.168\.100\.[0-9]+/32' || true)"
    [[ "$adv_count" -ge 1 ]] && ok "$nname: advertising $adv_count VIP /32(s)" \
                             || nok "$nname: advertising 0 VIPs"

    run_cmd "2.$nname routes available (locally-originated Loc-RIB view)" \
            "kubectl -n kube-system exec $pod -c cilium-agent -- cilium-dbg bgp routes available ipv4 unicast" \
            "kubectl -n kube-system exec '$pod' -c cilium-agent -- cilium-dbg bgp routes available ipv4 unicast"
    local avail_count
    avail_count="$(echo "$OUT" | grep -cE '192\.168\.100\.[0-9]+/32' || true)"
    [[ "$avail_count" -ge 1 ]] && ok "$nname: $avail_count VIP(s) locally available" \
                               || nok "$nname: no VIPs in local RIB"
  done
}

# =============================================================================
# Section 3 - Host kernel routing (netplan static route for VIP pool)
# =============================================================================
section_host_routes() {
  banner "3. Host kernel routes (VIP pool pinned to ens4)"

  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" nip="$(n_ip "$n")" leaf="$(n_leaf "$n")"

    run_cmd "3.$nname ip route show dev ens4" \
            "[$nname] ip route show dev ens4" \
            "$(node_cmd_str "$nname" "$nip" "ip route show dev ens4")"
    # Accept either the narrow pool /24 or the supernet /16 — both cover the VIPs.
    check "$nname: VIP route via $leaf (pool /24 or supernet /16)"  \
          "echo \"\$OUT\" | grep -qE '(192\\.168\\.100\\.0/24|192\\.168\\.0\\.0/16).*via $leaf'"

    run_cmd "3.$nname ip route get 192.168.100.0" \
            "[$nname] ip route get 192.168.100.0" \
            "$(node_cmd_str "$nname" "$nip" "ip route get 192.168.100.0")"
    check "$nname: resolves via $leaf dev ens4" \
          "echo \"\$OUT\" | grep -q 'via $leaf dev ens4'"
  done
}

# =============================================================================
# Section 4 - VIP reachability (curl each LB service from each node)
# =============================================================================
section_reachability() {
  banner "4. VIP reachability (curl each VIP from every node)"

  local vips
  vips="$(kubectl get svc -A --field-selector spec.type=LoadBalancer \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    | grep -v '=$' | grep -vE '^(kube-system|kube-public)/' || true)"

  if [[ -z "$vips" ]]; then nok "no VIPs to test"; return; fi

  for n in "${NODES[@]}"; do
    local nname="$(n_name "$n")" nip="$(n_ip "$n")"
    while IFS='=' read -r svc vip; do
      [[ -z "$vip" ]] && continue
      run_cmd "4.$nname -> $svc @ $vip" \
              "[$nname] curl -s --max-time 5 http://$vip/" \
              "$(node_cmd_str "$nname" "$nip" "curl -s --max-time 5 http://$vip/")"
      local first_line
      first_line="$(echo "$OUT" | head -1)"
      if [[ -n "$first_line" ]] && ! echo "$first_line" | grep -qiE 'error|timed out|refused|^$'; then
        ok "$nname: got response \"$first_line\""
      else
        nok "$nname -> $vip failed"
      fi
    done <<< "$vips"
  done
}

# =============================================================================
# Section 5 - Fabric (NX-OS) - one SSH session per leaf (batched)
# =============================================================================
section_fabric() {
  banner "5. Fabric (NX-OS leaves) - BGP VRF + RIB + EVPN"

  # The command list. Order matters: nxos_batch_section uses it as index.
  local cmds=(
    "show bgp ipv4 unicast summary vrf tenant-1"    # 0
    "show ip bgp vrf tenant-1"                      # 1
    "show ip route 192.168.100.0 vrf tenant-1"      # 2
    "show ip route 192.168.100.1 vrf tenant-1"      # 3
    "show ip route 192.168.100.2 vrf tenant-1"      # 4
    "show ip route 192.168.100.3 vrf tenant-1"      # 5
    "show bgp l2vpn evpn | include 192.168.100"     # 6
    "show running-config bgp"                        # 7
    "show ip bgp vrf tenant-1 $SUPERNET"             # 8  (supernet aggregate + advertised-to-peers)
  )

  for lf in "${LEAVES[@]}"; do
    local lname="$(l_name "$lf")" svi="$(l_svi "$lf")"
    local hip="$(l_host_ip "$lf")" has="$(l_host_as "$lf")" hnm="$(l_host_nm "$lf")"

    printf "\n%s────────── %s (SVI %s, peer %s/%s) ──────────%s\n" \
           "$BOLD$BLUE" "$lname" "$svi" "$hnm" "$has" "$NC"
    printf "%s[i]%s running %d show commands in a single SSH session\n" \
           "$BLUE" "$NC" "${#cmds[@]}"

    nxos_batch_run "$svi" "${cmds[@]}"
    if [[ -z "$LEAF_BATCH_RAW" ]]; then
      nok "$lname: batched SSH returned no output (auth/timeout?)"
      continue
    fi

    # 5.1 BGP summary in tenant-1
    show_cmd_output "5.$lname.1 show bgp ipv4 unicast summary vrf tenant-1" \
                    "ssh $LEAF_USER@$svi 'show bgp ipv4 unicast summary vrf tenant-1'" \
                    "$(nxos_batch_section 0)"
    check "$lname: neighbor $hip present"     "echo \"\$OUT\" | grep -q '$hip'"
    check "$lname: neighbor AS=$has"           "echo \"\$OUT\" | awk -v ip='$hip' '\$1==ip' | grep -q '$has'"
    check "$lname: session Established (PfxRcd column is numeric)" \
          "echo \"\$OUT\" | awk -v ip='$hip' '\$1==ip {print \$NF}' | grep -Eq '^[0-9]+\$'"
    check "$lname: PfxRcd >= 1 from host" \
          "[[ \"\$(echo \"\$OUT\" | awk -v ip='$hip' '\$1==ip {print \$NF}')\" -ge 1 ]]"

    # 5.2 BGP table in tenant-1
    show_cmd_output "5.$lname.2 show ip bgp vrf tenant-1" \
                    "ssh $LEAF_USER@$svi 'show ip bgp vrf tenant-1'" \
                    "$(nxos_batch_section 1)"
    local vip32_count
    vip32_count="$(echo "$OUT" | grep -cE '192\.168\.100\.[0-9]+/32' || true)"
    [[ "$vip32_count" -ge 4 ]] \
      && ok "$lname: $vip32_count VIP /32(s) in BGP table (expected >= 4)" \
      || nok "$lname: only $vip32_count VIP /32s in BGP table (expected >= 4)"
    check "$lname: local eBGP path present (*>e via host)" \
          "echo \"\$OUT\" | grep -Eq '\\*>e.*$hip'"

    # 5.3 FIB per /32
    for octet in 0 1 2 3; do
      local vip="192.168.100.$octet"
      local sidx=$((2 + octet))
      show_cmd_output "5.$lname.3.$octet show ip route $vip vrf tenant-1" \
                      "ssh $LEAF_USER@$svi 'show ip route $vip vrf tenant-1'" \
                      "$(nxos_batch_section $sidx)"
      check "$lname: $vip/32 next-hop is $hip (local host)" \
            "echo \"\$OUT\" | grep -Eq 'via $hip'"
      check "$lname: $vip/32 tagged bgp-65000 external" \
            "echo \"\$OUT\" | grep -q 'bgp-65000, external'"
    done

    # 5.4 EVPN Type-5
    show_cmd_output "5.$lname.4 show bgp l2vpn evpn | include 192.168.100" \
                    "ssh $LEAF_USER@$svi 'show bgp l2vpn evpn | include 192.168.100'" \
                    "$(nxos_batch_section 6)"
    check "$lname: originates its own type-5 VIP routes (*>l)" \
          "echo \"\$OUT\" | grep -Eq '\\*>l\\[5\\]:\\[0\\]:\\[0\\]:\\[32\\]:\\[192\\.168\\.100\\.'"
    check "$lname: imports type-5 VIPs from peer VTEPs (* i)" \
          "echo \"\$OUT\" | grep -Eq '\\* i\\[5\\]:\\[0\\]:\\[0\\]:\\[32\\]:\\[192\\.168\\.100\\.'"

    # 5.5 Running config (tenant-1 neighbor sanity)
    show_cmd_output "5.$lname.5 show running-config bgp" \
                    "ssh $LEAF_USER@$svi 'show running-config bgp'" \
                    "$(nxos_batch_section 7)"
    check "$lname: VRF tenant-1 present"             "echo \"\$OUT\" | grep -q 'vrf tenant-1'"
    check "$lname: neighbor $hip configured"         "echo \"\$OUT\" | grep -q 'neighbor $hip'"
    check "$lname: K8S-HOST-IN route-map inbound"    "echo \"\$OUT\" | grep -q 'route-map K8S-HOST-IN in'"
    check "$lname: K8S-HOST-OUT route-map outbound"  "echo \"\$OUT\" | grep -q 'route-map K8S-HOST-OUT out'"
    check "$lname: maximum-paths ibgp 4 in VRF"      "echo \"\$OUT\" | grep -q 'maximum-paths ibgp 4'"

    # 5.6 Supernet aggregate + advertised-to-host (fabric-side proof of
    # the BGP UPDATE whose receipt is counted as Received: 1 on the Cilium
    # side. cilium-dbg in 1.18 does not surface Adj-RIB-In content, so this
    # is where we confirm the specific prefix is actually on the wire.)
    show_cmd_output "5.$lname.6 show ip bgp vrf tenant-1 $SUPERNET" \
                    "ssh $LEAF_USER@$svi 'show ip bgp vrf tenant-1 $SUPERNET'" \
                    "$(nxos_batch_section 8)"
    check "$lname: $SUPERNET present in BGP RIB" \
          "echo \"\$OUT\" | grep -q 'BGP routing table entry for $SUPERNET'"
    check "$lname: $SUPERNET is locally-originated aggregate best path" \
          "echo \"\$OUT\" | grep -Eq 'Path type: aggregate.*is best path'"
    check "$lname: $SUPERNET advertised to $hip (rack host)" \
          "echo \"\$OUT\" | awk '/Path-id.*advertised to peers:/,0' | grep -q '$hip'"
  done
}

# =============================================================================
# Summary
# =============================================================================
summary() {
  banner "Summary"
  local total=$((PASS+FAIL))
  printf "   %sPassed:%s %s%d%s / %d\n" "$BOLD" "$NC" "$GREEN" "$PASS" "$NC" "$total"
  printf "   %sFailed:%s %s%d%s / %d\n" "$BOLD" "$NC" "$RED"   "$FAIL" "$NC" "$total"
  printf "   %sTranscript:%s %s\n" "$BOLD" "$NC" "$LOG_FILE"
  echo
  if [[ "$FAIL" -eq 0 ]]; then
    printf "%s  ALL CHECKS PASSED%s\n" "$BOLD$GREEN" "$NC"
    exit 0
  else
    printf "%s  SOME CHECKS FAILED — review the ✗ lines above%s\n" "$BOLD$RED" "$NC"
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  printf "%sValidation run: %s%s\n" "$BOLD" "$(date -Iseconds)" "$NC"
  printf "%sLog: %s%s\n" "$BOLD" "$LOG_FILE" "$NC"

  check_prereqs
  section_cluster
  section_cilium_bgp
  section_host_routes
  section_reachability
  section_fabric
  summary
}

main "$@"
