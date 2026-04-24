#!/usr/bin/env bash
# =============================================================================
# productionize_bgp.sh
# -----------------------------------------------------------------------------
# Migrate from Cilium-BGP + netplan-static-supernet to FRR-everywhere with
# BFD for sub-second failure detection.
#
# What this does:
#   1. Install FRR on every host (apt).
#   2. Create K8s RBAC (SA + ClusterRole + Secret) + a per-host kubeconfig
#      that has list-services only.
#   3. Deploy vip-sync: tiny bash daemon that lists LB Services every 30s and
#      maintains matching /32s on `lo`. FRR redistribute-connected + prefix
#      filter picks them up for advertisement.
#   4. Write FRR config (BGP + BFD) — NOT started yet.
#   5. Enable BFD on every leaf's eBGP neighbor (no-op while Cilium is still
#      speaker; Cilium doesn't answer BFD).
#   6. Cutover (brief flap): delete Cilium BGP CRs, start vip-sync, start FRR.
#   7. Remove 192.168.0.0/16 from netplan; rely on FRR-installed route.
#   8. Validate new state.
#
# Rollback: `./productionize_bgp.sh rollback` — best-effort restore of the
# pre-run state (re-applies Cilium BGP CRs from backup, stops FRR/vip-sync,
# removes BFD on leaves, restores netplan).
#
# Tested assumption: Cilium 1.18.x, kubeProxyReplacement enabled, NX-OS 10.x
# fabric already converged to leaf-mode (the output of migrate_bgp_to_leaf.sh).
# =============================================================================
set -uo pipefail

# ---- config -----------------------------------------------------------------
readonly WORKDIR="$(pwd)/productionize-bgp"
readonly BACKUP_DIR="$WORKDIR/backup"
readonly SSH_USER="${SSH_USER:-user}"
readonly SW_USER="${SW_USER:-admin}"
readonly SW_PASS="${SW_PASS:-admin}"
readonly VIP_SUPERNET="${VIP_SUPERNET:-192.168.0.0/16}"

# BFD: 600ms detection (3 × 200ms). Tune if your fabric/host is flappy.
readonly BFD_RX_MS="${BFD_RX_MS:-200}"
readonly BFD_TX_MS="${BFD_TX_MS:-200}"
readonly BFD_MULT="${BFD_MULT:-3}"

# Format: name:host-ens4-IP:leaf-SVI-IP:host-AS:vlan-id
readonly NODES=(
  "master:10.1.1.10:10.1.1.1:65201:11"
  "worker-1:10.1.2.10:10.1.2.1:65202:12"
  "worker-2:10.1.3.10:10.1.3.1:65203:13"
  "worker-3:10.1.4.10:10.1.4.1:65204:14"
)

readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes"
readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"

# ---- display helpers -------------------------------------------------------
BOLD=$'\033[1m'; NC=$'\033[0m'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'

banner()  { printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n"  "$BOLD$MAGENTA" "$NC"
            printf "%s  %s%s\n"                                              "$BOLD$MAGENTA" "$*" "$NC"
            printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n"    "$BOLD$MAGENTA" "$NC"; }
section() { printf "\n%s── %s%s\n" "$BOLD$CYAN" "$*" "$NC"; }
info()    { printf "%s[i]%s %s\n"  "$BLUE"   "$NC" "$*"; }
ok()      { printf "%s[+]%s %s\n"  "$GREEN"  "$NC" "$*"; }
warn()    { printf "%s[!]%s %s\n"  "$YELLOW" "$NC" "$*"; }
err()     { printf "%s[x]%s %s\n"  "$RED"    "$NC" "$*"; }

# ---- field extractors -------------------------------------------------------
n_name(){ echo "$1" | cut -d: -f1; }
n_ip()  { echo "$1" | cut -d: -f2; }
n_svi() { echo "$1" | cut -d: -f3; }
n_as()  { echo "$1" | cut -d: -f4; }
n_vlan(){ echo "$1" | cut -d: -f5; }

ssh_h() { ssh $SSH_OPTS "$SSH_USER@$1" "$2"; }
scp_h() { scp $SSH_OPTS "$1" "$SSH_USER@$2:$3"; }

# =============================================================================
# PREFLIGHT
# =============================================================================
preflight() {
  banner "Preflight"
  command -v kubectl >/dev/null || { err "kubectl missing"; exit 1; }
  command -v sshpass >/dev/null || { sudo apt-get install -y -qq sshpass; }
  command -v jq      >/dev/null || { sudo apt-get install -y -qq jq; }
  kubectl get nodes >/dev/null 2>&1 || { err "kubectl: cluster unreachable"; exit 1; }
  mkdir -p "$WORKDIR" "$BACKUP_DIR"
  ok "kubectl, sshpass, jq available"
  ok "working dir: $WORKDIR"

  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    ssh_h "$ip" 'hostname' >/dev/null || { err "$nm ($ip): ssh broken"; exit 1; }
    ssh_h "$ip" 'sudo -n true'        || { err "$nm ($ip): NOPASSWD sudo missing"; exit 1; }
    ok "$nm: ssh + sudo ok"
  done
}

# =============================================================================
# STAGE 0 - backup current state
# =============================================================================
stage0_backup() {
  banner "Stage 0 - Backup current state"
  kubectl get ciliumbgpclusterconfig  -o yaml > "$BACKUP_DIR/cilium-bgp-cluster.yaml" 2>/dev/null || true
  kubectl get ciliumbgppeerconfig     -o yaml > "$BACKUP_DIR/cilium-bgp-peer.yaml"    2>/dev/null || true
  kubectl get ciliumbgpadvertisement  -o yaml > "$BACKUP_DIR/cilium-bgp-adv.yaml"     2>/dev/null || true
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    ssh_h "$ip" 'cat /etc/netplan/60-fabric.yaml 2>/dev/null' > "$BACKUP_DIR/netplan-${nm}.yaml" || true
  done
  ok "backups under $BACKUP_DIR/"
}

# =============================================================================
# STAGE 1 - install FRR on hosts
# =============================================================================
stage1_install_frr() {
  banner "Stage 1 - Install FRR on all hosts"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    section "$nm"
    ssh_h "$ip" 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
                 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq frr frr-pythontools' \
      || { err "$nm: frr install failed"; return 1; }
    # Enable bgpd and bfdd in the daemons file
    ssh_h "$ip" "sudo sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons; \
                 sudo sed -i 's/^bfdd=no/bfdd=yes/' /etc/frr/daemons" || true
    ok "$nm: frr installed, bgpd+bfdd enabled"
  done
}

# =============================================================================
# STAGE 2 - K8s RBAC + per-host kubeconfig for vip-sync
# =============================================================================
stage2_rbac() {
  banner "Stage 2 - K8s RBAC + vip-sync kubeconfig"

  cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: { name: vip-sync, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: vip-sync-reader }
rules:
- apiGroups: [""]
  resources: ["services"]
  verbs: ["list", "watch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: vip-sync-binding }
subjects: [{ kind: ServiceAccount, name: vip-sync, namespace: kube-system }]
roleRef:  { kind: ClusterRole, name: vip-sync-reader, apiGroup: rbac.authorization.k8s.io }
---
apiVersion: v1
kind: Secret
metadata:
  name: vip-sync-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: vip-sync }
type: kubernetes.io/service-account-token
YAML

  info "waiting for token to populate..."
  for _ in $(seq 1 20); do
    kubectl -n kube-system get secret vip-sync-token \
      -o jsonpath='{.data.token}' 2>/dev/null | grep -q . && break
    sleep 1
  done

  local token ca server
  token=$(kubectl -n kube-system get secret vip-sync-token -o jsonpath='{.data.token}' | base64 -d)
  ca=$(   kubectl -n kube-system get secret vip-sync-token -o jsonpath='{.data.ca\.crt}')
  server=$(kubectl config view --minify --flatten -o jsonpath='{.clusters[0].cluster.server}')

  [[ -z "$token" || -z "$ca" || -z "$server" ]] && { err "failed to extract SA token"; exit 1; }

  cat > "$WORKDIR/vip-sync.kubeconfig" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $server
    certificate-authority-data: $ca
  name: cluster
contexts:
- context: { cluster: cluster, user: vip-sync }
  name: vip-sync-ctx
current-context: vip-sync-ctx
users:
- name: vip-sync
  user: { token: $token }
KUBECONFIG
  chmod 600 "$WORKDIR/vip-sync.kubeconfig"
  ok "kubeconfig ready: $WORKDIR/vip-sync.kubeconfig"
}

# =============================================================================
# STAGE 3 - deploy vip-sync on every host
# =============================================================================
vip_sync_script() {
  cat <<'VIPSYNC'
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
VIPSYNC
}

vip_sync_service() {
  cat <<'SVC'
[Unit]
Description=VIP sync (Kubernetes LoadBalancer IPs -> lo)
After=network.target kubelet.service
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vip-sync.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC
}

stage3_deploy_vip_sync() {
  banner "Stage 3 - Deploy vip-sync daemon"
  local script_file="$WORKDIR/vip-sync.sh"
  local service_file="$WORKDIR/vip-sync.service"
  vip_sync_script  > "$script_file"
  vip_sync_service > "$service_file"

  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    section "$nm"
    scp_h "$script_file"  "$ip" /tmp/vip-sync.sh         || { err "scp script fail"; return 1; }
    scp_h "$service_file" "$ip" /tmp/vip-sync.service    || { err "scp svc fail"; return 1; }
    scp_h "$WORKDIR/vip-sync.kubeconfig" "$ip" /tmp/vip-sync.kubeconfig || { err "scp kc fail"; return 1; }

    ssh_h "$ip" '
      set -e
      sudo install -m 0755 /tmp/vip-sync.sh /usr/local/bin/vip-sync.sh
      sudo install -d -m 0755 /etc/vip-sync
      sudo install -m 0600 /tmp/vip-sync.kubeconfig /etc/vip-sync/kubeconfig
      sudo install -m 0644 /tmp/vip-sync.service /etc/systemd/system/vip-sync.service
      rm -f /tmp/vip-sync.sh /tmp/vip-sync.service /tmp/vip-sync.kubeconfig
      sudo systemctl daemon-reload
      sudo systemctl enable vip-sync.service
    ' || { err "$nm: deploy failed"; return 1; }
    ok "$nm: vip-sync installed (not started — cutover stage will start)"
  done
}

# =============================================================================
# STAGE 4 - write FRR config (not started yet)
# =============================================================================
gen_frr_conf() {
  local nm="$1" ip="$2" leaf="$3" as="$4"
  cat <<FRR
frr defaults traditional
hostname $nm
log syslog informational
service integrated-vtysh-config
!
ip prefix-list VIP-SUPERNET seq 10 permit $VIP_SUPERNET le 32
!
route-map VIP-FILTER permit 10
 match ip address prefix-list VIP-SUPERNET
!
bfd
 profile FAST-BGP
  transmit-interval $BFD_TX_MS
  receive-interval $BFD_RX_MS
  detect-multiplier $BFD_MULT
 exit
exit
!
router bgp $as
 bgp router-id $ip
 no bgp ebgp-requires-policy
 no bgp default ipv4-unicast
 timers bgp 30 90
 neighbor $leaf remote-as 65000
 neighbor $leaf description leaf-svi
 neighbor $leaf bfd
 neighbor $leaf bfd profile FAST-BGP
 !
 address-family ipv4 unicast
  redistribute connected route-map VIP-FILTER
  neighbor $leaf activate
  neighbor $leaf route-map VIP-FILTER in
  neighbor $leaf route-map VIP-FILTER out
 exit-address-family
exit
!
end
FRR
}

stage4_frr_config() {
  banner "Stage 4 - Write FRR configs (not started yet)"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n") leaf=$(n_svi "$n") as=$(n_as "$n")
    section "$nm"
    local cfg="$WORKDIR/frr-${nm}.conf"
    gen_frr_conf "$nm" "$ip" "$leaf" "$as" > "$cfg"
    scp_h "$cfg" "$ip" /tmp/frr.conf || { err "$nm: scp failed"; return 1; }
    ssh_h "$ip" '
      sudo install -m 0640 -g frr -o frr /tmp/frr.conf /etc/frr/frr.conf
      rm -f /tmp/frr.conf
    ' || { err "$nm: install failed"; return 1; }
    ok "$nm: /etc/frr/frr.conf deployed"
  done
}

# =============================================================================
# STAGE 5 - enable BFD on NX-OS leaves (safe while Cilium still speaker)
# =============================================================================
stage5_leaf_bfd() {
  banner "Stage 5 - Enable BFD on leaves (BGP neighbors, $BFD_RX_MS/$BFD_TX_MS/$BFD_MULT)"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") hip=$(n_ip "$n") leaf=$(n_svi "$n") vlan=$(n_vlan "$n")
    section "Leaf for $nm ($leaf, Vlan$vlan)"
    local cfg=$(cat <<CFG
terminal length 0
conf t
feature bfd
interface Vlan$vlan
  bfd interval $BFD_TX_MS min_rx $BFD_RX_MS multiplier $BFD_MULT
  no shutdown
exit
router bgp 65000
 vrf tenant-1
  neighbor $hip
   bfd
   exit
  exit
 exit
end
copy running-config startup-config
show run bfd
show bfd neighbors
exit
CFG
)
    local out
    out=$(timeout 30 sshpass -p "$SW_PASS" ssh -T $SSH_OPTS_NXOS "$SW_USER@$leaf" <<<"$cfg" 2>&1) || true
    if [[ -z "$out" ]]; then err "leaf $leaf: no output"; continue; fi
    echo "$out" | sed 's/^/    /'
    ok "leaf $leaf: BFD configured (no session yet — Cilium is not BFD-capable)"
  done
}

# =============================================================================
# STAGE 6 - CUTOVER: delete Cilium BGP → start FRR + vip-sync
# =============================================================================
stage6_cutover() {
  banner "Stage 6 - Cutover (brief BGP flap expected)"
  warn "from this point until FRR peers converge, VIPs routed via OTHER racks"
  warn "may be unreachable for ~10-30s. Same-rack pod traffic is unaffected."

  section "Delete Cilium BGP CRs"
  kubectl delete ciliumbgpclusterconfig --all --ignore-not-found
  kubectl delete ciliumbgpadvertisement --all --ignore-not-found
  kubectl delete ciliumbgppeerconfig    --all --ignore-not-found
  ok "Cilium BGP CRs removed"

  section "Start vip-sync + FRR on each host"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    ssh_h "$ip" '
      sudo systemctl start vip-sync.service
      sudo systemctl restart frr.service
    ' || { err "$nm: start failed"; return 1; }
    ok "$nm: vip-sync + frr started"
  done

  info "sleeping 20s for BGP+BFD convergence..."
  sleep 20
}

# =============================================================================
# STAGE 7 - remove netplan VIP supernet static
# =============================================================================
stage7_netplan_drop() {
  banner "Stage 7 - Drop 192.168.0.0/16 from netplan"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    section "$nm"
    ssh_h "$ip" "
      sudo python3 - <<PY
import yaml, pathlib, sys
p = pathlib.Path('/etc/netplan/60-fabric.yaml')
if not p.exists(): sys.exit(0)
d = yaml.safe_load(p.read_text()) or {}
for _, nic in (d.get('network',{}).get('ethernets',{}) or {}).items():
    if 'routes' in nic:
        nic['routes'] = [r for r in nic['routes']
                         if not str(r.get('to','')).startswith('$VIP_SUPERNET'.split('/')[0])]
p.write_text(yaml.safe_dump(d))
PY
      sudo chmod 0600 /etc/netplan/60-fabric.yaml
      sudo netplan apply
    " || { err "$nm: netplan edit failed"; return 1; }
    ok "$nm: netplan updated, supernet removed"
  done
  info "sleeping 5s for kernel to settle..."; sleep 5
}

# =============================================================================
# STAGE 8 - validate new state
# =============================================================================
stage8_validate() {
  banner "Stage 8 - Validate"
  local fail=0
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n") leaf=$(n_svi "$n")
    section "$nm"

    # vip-sync + frr healthy
    local v_state f_state
    v_state=$(ssh_h "$ip" 'systemctl is-active vip-sync' 2>/dev/null || echo dead)
    f_state=$(ssh_h "$ip" 'systemctl is-active frr'      2>/dev/null || echo dead)
    [[ "$v_state" == active ]] && ok "$nm: vip-sync active" || { err "$nm: vip-sync $v_state"; fail=$((fail+1)); }
    [[ "$f_state" == active ]] && ok "$nm: frr active"     || { err "$nm: frr $f_state"; fail=$((fail+1)); }

    # BGP session up
    local bgp_state
    bgp_state=$(ssh_h "$ip" "sudo vtysh -c 'show bgp summary' 2>/dev/null | awk -v p='$leaf' '\$1==p {print \$10}'")
    if [[ "$bgp_state" =~ ^[0-9]+$ ]]; then
      ok "$nm: BGP established, $bgp_state prefix(es) received"
    else
      err "$nm: BGP session not up (state=$bgp_state)"
      fail=$((fail+1))
    fi

    # BFD session up
    local bfd_state
    bfd_state=$(ssh_h "$ip" "sudo vtysh -c 'show bfd peers' 2>/dev/null | awk -v p='$leaf' '\$0 ~ p {getline; if (\$2==\"up\") print \"up\"}'")
    [[ "$bfd_state" == up ]] && ok "$nm: BFD up" || { err "$nm: BFD not up"; fail=$((fail+1)); }

    # Supernet in kernel FIB from FRR (proto bgp)
    local kr
    kr=$(ssh_h "$ip" "ip route show $VIP_SUPERNET 2>/dev/null | grep -c 'proto bgp' || true")
    [[ "$kr" -ge 1 ]] && ok "$nm: kernel has $VIP_SUPERNET proto bgp" \
                      || { err "$nm: kernel missing BGP-installed supernet"; fail=$((fail+1)); }

    # VIP /32s on lo
    local lo_count
    lo_count=$(ssh_h "$ip" "ip -4 addr show dev lo | grep -c '192\\.168\\.'")
    [[ "$lo_count" -ge 1 ]] && ok "$nm: vip-sync has $lo_count VIP(s) on lo" \
                            || { err "$nm: no VIPs on lo"; fail=$((fail+1)); }
  done

  echo
  if [[ "$fail" -eq 0 ]]; then
    banner "SUCCESS - FRR + BFD live, netplan dropped"
    info "Run ./validate_leaf.bgp.sh to confirm the full picture."
    info "Run 'sudo vtysh -c \"show bfd peers\"' on any host for BFD details."
  else
    err "$fail validation check(s) failed — see above. Consider: $0 rollback"
  fi
  return "$fail"
}

# =============================================================================
# ROLLBACK
# =============================================================================
rollback() {
  banner "ROLLBACK - restoring pre-productionize state"

  section "Stop FRR + vip-sync, restore netplan"
  for n in "${NODES[@]}"; do
    local nm=$(n_name "$n") ip=$(n_ip "$n")
    ssh_h "$ip" '
      sudo systemctl stop frr.service      2>/dev/null || true
      sudo systemctl stop vip-sync.service 2>/dev/null || true
      sudo systemctl disable frr.service      2>/dev/null || true
      sudo systemctl disable vip-sync.service 2>/dev/null || true
      # strip any VIPs we added to lo
      for a in $(ip -4 -o addr show dev lo | awk "/192\\.168\\./ {print \$4}"); do
        sudo ip addr del "$a" dev lo 2>/dev/null || true
      done
    ' || warn "$nm: cleanup errors (continuing)"
    if [[ -f "$BACKUP_DIR/netplan-${nm}.yaml" && -s "$BACKUP_DIR/netplan-${nm}.yaml" ]]; then
      scp_h "$BACKUP_DIR/netplan-${nm}.yaml" "$ip" /tmp/netplan-restore.yaml
      ssh_h "$ip" 'sudo install -m 0600 /tmp/netplan-restore.yaml /etc/netplan/60-fabric.yaml; sudo netplan apply; rm -f /tmp/netplan-restore.yaml'
    fi
    ok "$nm: rolled back"
  done

  section "Remove BFD from leaves"
  for n in "${NODES[@]}"; do
    local hip=$(n_ip "$n") leaf=$(n_svi "$n") vlan=$(n_vlan "$n")
    local cfg=$(cat <<CFG
terminal length 0
conf t
router bgp 65000
 vrf tenant-1
  neighbor $hip
   no bfd
   exit
  exit
 exit
interface Vlan$vlan
  no bfd interval $BFD_TX_MS min_rx $BFD_RX_MS multiplier $BFD_MULT
exit
end
copy running-config startup-config
exit
CFG
)
    timeout 30 sshpass -p "$SW_PASS" ssh -T $SSH_OPTS_NXOS "$SW_USER@$leaf" <<<"$cfg" >/dev/null 2>&1 || true
    ok "leaf $leaf: BFD removed"
  done

  section "Reapply Cilium BGP CRs from backup"
  for f in cilium-bgp-peer.yaml cilium-bgp-cluster.yaml cilium-bgp-adv.yaml; do
    [[ -s "$BACKUP_DIR/$f" ]] && kubectl apply -f "$BACKUP_DIR/$f" || warn "$f missing/empty"
  done
  ok "Cilium BGP restored (give it ~30s to re-establish)"

  section "Remove vip-sync SA"
  kubectl -n kube-system delete sa vip-sync --ignore-not-found
  kubectl -n kube-system delete secret vip-sync-token --ignore-not-found
  kubectl delete clusterrole vip-sync-reader --ignore-not-found
  kubectl delete clusterrolebinding vip-sync-binding --ignore-not-found

  banner "Rollback complete"
}

# =============================================================================
# MAIN
# =============================================================================
usage() {
  cat <<USAGE
Usage: $0 <apply|rollback|help>

  apply     Run stages 0-8 (backup, install FRR, deploy vip-sync, wire BFD,
            cutover, drop netplan, validate).
  rollback  Best-effort restore of pre-apply state using $BACKUP_DIR.
  help      This help.

Environment overrides:
  VIP_SUPERNET  (default 192.168.0.0/16)
  BFD_RX_MS / BFD_TX_MS / BFD_MULT  (default 200/200/3 = ~600ms detection)
  SW_USER / SW_PASS                 (default admin/admin)
  SSH_USER                          (default user)
USAGE
}

main() {
  case "${1:-help}" in
    apply)
      preflight
      stage0_backup
      stage1_install_frr
      stage2_rbac
      stage3_deploy_vip_sync
      stage4_frr_config
      stage5_leaf_bfd
      stage6_cutover
      stage7_netplan_drop
      stage8_validate
      ;;
    rollback) rollback ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
