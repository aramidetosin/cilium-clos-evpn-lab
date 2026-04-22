#!/usr/bin/env bash
# =============================================================================
# Kubernetes + Cilium + Node-to-Node BGP POC
# =============================================================================
# Run this script FROM the master host (10.1.1.10).
# It operates on master locally and on worker-1/2/3 via passwordless SSH.
#
# Topology:
#   master   10.1.1.10   ens4 -> Leaf-1   AS 65201  (control plane + worker)
#   worker-1 10.1.2.10   ens4 -> Leaf-2   AS 65202
#   worker-2 10.1.3.10   ens4 -> Leaf-3   AS 65203
#   worker-3 10.1.4.10   ens4 -> Leaf-4   AS 65204
#
# What gets built:
#   - kubeadm cluster, K8s 1.31, kube-proxy skipped, master untainted
#   - Cilium 1.18.4, VXLAN overlay, eBPF kubeProxyReplacement, device=ens4
#   - Cilium BGP control plane: 4-way full-mesh eBGP between nodes
#   - LoadBalancer IP pool 192.168.100.0/24, advertised over node-to-node BGP
#   - 4 AI-training-style services (param-server, trainer, inference, data-loader)
#
# Fabric is untouched (no BGP config on leaves). Leaf-level reachability between
# nodes is underlay-only (OSPF loopbacks carry the fabric already).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Config
# -----------------------------------------------------------------------------
readonly LAB_DIR="$(pwd)/k8s-cilium-lab"
readonly MANIFESTS_DIR="${LAB_DIR}/manifests"
readonly SCRIPTS_DIR="${LAB_DIR}/scripts"
readonly LOGS_DIR="${LAB_DIR}/logs"

readonly K8S_MINOR="1.31"
readonly K8S_VERSION_FULL="v1.31.2"
readonly CILIUM_VERSION="1.18.4"
readonly POD_CIDR="10.10.0.0/16"
readonly SVC_CIDR="10.96.0.0/16"
readonly VIP_POOL_CIDR="192.168.100.0/24"

readonly MASTER_HOSTNAME="master"
readonly MASTER_IP="10.1.1.10"
readonly MASTER_ASN="65201"

# Workers: hostname:fabric-ip:asn
readonly WORKER_1="worker-1:10.1.2.10:65202"
readonly WORKER_2="worker-2:10.1.3.10:65203"
readonly WORKER_3="worker-3:10.1.4.10:65204"
readonly WORKERS=("$WORKER_1" "$WORKER_2" "$WORKER_3")

readonly SSH_USER="${SSH_USER:-user}"
readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# -----------------------------------------------------------------------------
# Flags
# -----------------------------------------------------------------------------
INTERACTIVE=false
CLEANUP_ONLY=false
SKIP_PREREQS=false

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --cleanup         Tear down cluster and exit
  --interactive     Pause between phases
  --no-pause        Default. Run to completion
  --skip-prereqs    Skip apt/containerd install (safe re-runs)
  -h, --help

Run from the master node. Requires passwordless SSH + NOPASSWD sudo on all 4 hosts.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup)      CLEANUP_ONLY=true; shift ;;
    --interactive)  INTERACTIVE=true;  shift ;;
    --no-pause)     INTERACTIVE=false; shift ;;
    --skip-prereqs) SKIP_PREREQS=true; shift ;;
    -h|--help)      usage; exit 0 ;;
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
show_cmd(){ printf "%s  $ %s%s\n" "${YELLOW}" "$*" "${NC}" >&2; }

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
# SSH helpers
# -----------------------------------------------------------------------------
ssh_w() {
  local target="$1"; shift
  ssh $SSH_OPTS "$SSH_USER@$target" "$@"
}
scp_w() {
  local src="$1" target="$2" dst="$3"
  scp -q $SSH_OPTS "$src" "$SSH_USER@$target:$dst"
}

# For each worker spec "name:ip:asn", emit fields
w_name() { echo "$1" | cut -d: -f1; }
w_ip()   { echo "$1" | cut -d: -f2; }
w_asn()  { echo "$1" | cut -d: -f3; }

worker_ips()    { for w in "${WORKERS[@]}"; do w_ip "$w"; done; }
worker_names()  { for w in "${WORKERS[@]}"; do w_name "$w"; done; }

# Run a script file on master (sudo) and on every worker (sudo via ssh)
run_everywhere() {
  local script_file="$1"
  local base="$(basename "$script_file")"
  info "Running $base on master"
  sudo bash "$script_file"
  for w in "${WORKERS[@]}"; do
    local wip="$(w_ip "$w")"
    info "Running $base on $(w_name "$w") ($wip)"
    scp_w "$script_file" "$wip" "/tmp/$base"
    ssh_w "$wip" "sudo bash /tmp/$base"
  done
}

# Pick any cilium-agent pod on a given node
cilium_pod_on() {
  local node="$1"
  kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector "spec.nodeName=$node" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Prereq check (Phase 0)
# -----------------------------------------------------------------------------
check_prereqs() {
  section "Phase 0: Prerequisite check"
  local missing=0

  # Must be on master
  if ! ip -4 addr show ens4 2>/dev/null | grep -q "$MASTER_IP"; then
    error "This script must run on master (expected $MASTER_IP on ens4)"
    error "  ens4 addresses are:"
    ip -4 addr show ens4 2>&1 | sed 's/^/    /' >&2 || true
    exit 1
  fi
  success "Running on master ($MASTER_IP)"

  # Local sudo
  if ! sudo -n true 2>/dev/null; then
    error "master: NOPASSWD sudo required for '$USER'"
    missing=$((missing+1))
  else
    success "master NOPASSWD sudo: OK"
  fi

  # Per-worker checks: SSH, sudo, internet
  for w in "${WORKERS[@]}"; do
    local wname="$(w_name "$w")" wip="$(w_ip "$w")"
    step "Checking $wname ($wip)"
    if ! ssh_w "$wip" "hostname" >/dev/null 2>&1; then
      error "$wname: SSH as '$SSH_USER' failed. Need passwordless SSH."
      error "  Hint: ssh-copy-id $SSH_USER@$wip  (from master)"
      missing=$((missing+1))
      continue
    fi
    local remote_hn
    remote_hn=$(ssh_w "$wip" "hostname")
    success "$wname: SSH OK (hostname=$remote_hn)"

    if ! ssh_w "$wip" "sudo -n true" 2>/dev/null; then
      error "$wname: NOPASSWD sudo required"
      error "  Fix: on $wname, run 'sudo visudo -f /etc/sudoers.d/99-$SSH_USER'"
      error "       add: $SSH_USER ALL=(ALL) NOPASSWD:ALL"
      missing=$((missing+1))
    else
      success "$wname: sudo NOPASSWD OK"
    fi

    if ! ssh_w "$wip" "curl -s --max-time 5 -o /dev/null https://registry.k8s.io"; then
      warn "$wname: cannot reach registry.k8s.io via ens3 (proceeding, may fail later)"
    else
      success "$wname: registry.k8s.io reachable"
    fi
  done

  # Helm on master
  if ! command -v helm >/dev/null 2>&1; then
    warn "helm not found on master - will install"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
  fi
  success "helm: $(helm version --short 2>/dev/null || echo 'unknown')"

  if [[ $missing -gt 0 ]]; then
    error "Fix the above prerequisites and re-run"
    exit 1
  fi
  pause
}

# -----------------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------------
do_cleanup() {
  section "Cleanup: teardown cluster and revert system"

  step "kubeadm reset on workers"
  for w in "${WORKERS[@]}"; do
    local wip="$(w_ip "$w")" wname="$(w_name "$w")"
    info "Resetting $wname"
    ssh_w "$wip" "
      sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock 2>/dev/null || true
      sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/etcd /var/lib/kubelet ~/.kube /tmp/*.sh
      sudo ip link delete cilium_host 2>/dev/null || true
      sudo ip link delete cilium_vxlan 2>/dev/null || true
      sudo ip link delete cilium_net 2>/dev/null || true
      sudo iptables -F 2>/dev/null || true
      sudo iptables -t nat -F 2>/dev/null || true
      sudo iptables -t mangle -F 2>/dev/null || true
      sudo sed -i '/# k8s-fabric-lab/d' /etc/hosts 2>/dev/null || true
    " || true
  done

  step "kubeadm reset on master"
  sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock 2>/dev/null || true
  sudo rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/etcd /var/lib/kubelet 2>/dev/null || true
  rm -rf ~/.kube 2>/dev/null || true
  sudo ip link delete cilium_host 2>/dev/null || true
  sudo ip link delete cilium_vxlan 2>/dev/null || true
  sudo ip link delete cilium_net 2>/dev/null || true
  sudo iptables -F 2>/dev/null || true
  sudo iptables -t nat -F 2>/dev/null || true
  sudo iptables -t mangle -F 2>/dev/null || true
  sudo sed -i '/# k8s-fabric-lab/d' /etc/hosts 2>/dev/null || true

  step "Remove helm release state"
  helm uninstall cilium -n kube-system 2>/dev/null || true

  success "Cleanup complete. Packages (kubelet/kubeadm/kubectl/containerd) left in place."
  info "To wipe those too: sudo apt-get purge -y kubelet kubeadm kubectl containerd"
}

if [[ "$CLEANUP_ONLY" == "true" ]]; then
  do_cleanup
  exit 0
fi

# -----------------------------------------------------------------------------
# Phase 1: Lab directory
# -----------------------------------------------------------------------------
setup_dirs() {
  section "Phase 1: Lab directory"
  rm -rf "$LAB_DIR"
  mkdir -p "$MANIFESTS_DIR" "$SCRIPTS_DIR" "$LOGS_DIR"
  info "LAB_DIR=$LAB_DIR"
}

# -----------------------------------------------------------------------------
# Phase 2: /etc/hosts on every node
# -----------------------------------------------------------------------------
setup_hosts_file() {
  section "Phase 2: /etc/hosts entries on every node"

  cat > "$SCRIPTS_DIR/hosts-entries.sh" <<EOF
#!/bin/bash
set -e
sed -i '/# k8s-fabric-lab/d' /etc/hosts
cat >> /etc/hosts <<HOSTS
$MASTER_IP $MASTER_HOSTNAME   # k8s-fabric-lab
$(w_ip "$WORKER_1") $(w_name "$WORKER_1")   # k8s-fabric-lab
$(w_ip "$WORKER_2") $(w_name "$WORKER_2")   # k8s-fabric-lab
$(w_ip "$WORKER_3") $(w_name "$WORKER_3")   # k8s-fabric-lab
HOSTS
EOF
  chmod +x "$SCRIPTS_DIR/hosts-entries.sh"
  show_file "$SCRIPTS_DIR/hosts-entries.sh"
  run_everywhere "$SCRIPTS_DIR/hosts-entries.sh"

  step "Verification (master)"
  grep 'k8s-fabric-lab' /etc/hosts | sed 's/^/  /' >&2
  pause
}

# -----------------------------------------------------------------------------
# Phase 3: System prep (containerd, kubeadm/kubelet/kubectl)
# -----------------------------------------------------------------------------
system_prep() {
  if [[ "$SKIP_PREREQS" == "true" ]]; then
    warn "Skipping system prep (--skip-prereqs)"
    return 0
  fi
  section "Phase 3: System prep on every node"

  cat > "$SCRIPTS_DIR/system-prep.sh" <<'SYSPREP'
#!/bin/bash
set -euo pipefail

# 1) swap off (permanently)
swapoff -a
sed -ri '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab || true

# 2) kernel modules
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 3) sysctl
cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.ipv4.ip_forward           = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system >/dev/null

# 4) containerd (from Ubuntu repo, v1.7.x is fine for K8s 1.31)
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y containerd apt-transport-https ca-certificates curl gpg socat conntrack ethtool

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# Align pause image with K8s expectation (avoids "pause image mismatch" warnings)
sed -i 's|sandbox_image = "registry.k8s.io/pause:[^"]*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# 5) Kubernetes apt repo and packages
mkdir -p /etc/apt/keyrings
# --yes forces overwrite without prompting (re-runs are idempotent)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "system-prep done on $(hostname)"
SYSPREP
  chmod +x "$SCRIPTS_DIR/system-prep.sh"
  run_everywhere "$SCRIPTS_DIR/system-prep.sh"
  success "System prep complete on all nodes"
  pause
}

# -----------------------------------------------------------------------------
# Phase 4: kubelet --node-ip drop-in on every node
# -----------------------------------------------------------------------------
setup_kubelet_node_ip() {
  section "Phase 4: kubelet --node-ip drop-in"

  _apply_dropin() {
    local host_label="$1" ip="$2"
    local cmd="
      sudo mkdir -p /etc/systemd/system/kubelet.service.d
      printf '[Service]\nEnvironment=\"KUBELET_EXTRA_ARGS=--node-ip=%s\"\n' '$ip' | \
        sudo tee /etc/systemd/system/kubelet.service.d/20-node-ip.conf >/dev/null
      sudo systemctl daemon-reload
    "
    if [[ "$host_label" == "master" ]]; then
      bash -c "$cmd"
    else
      ssh_w "$ip" "$cmd"
    fi
    success "$host_label kubelet --node-ip=$ip"
  }

  _apply_dropin master "$MASTER_IP"
  for w in "${WORKERS[@]}"; do
    _apply_dropin "$(w_name "$w")" "$(w_ip "$w")"
  done
  pause
}

# -----------------------------------------------------------------------------
# Phase 5: kubeadm init on master
# -----------------------------------------------------------------------------
kubeadm_init() {
  section "Phase 5: kubeadm init on master"

  cat > "$MANIFESTS_DIR/kubeadm-init.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: $K8S_VERSION_FULL
clusterName: k8s-fabric-lab
networking:
  podSubnet: $POD_CIDR
  serviceSubnet: $SVC_CIDR
controlPlaneEndpoint: "$MASTER_IP:6443"
apiServer:
  certSANs:
  - "$MASTER_IP"
  - "master"
  - "127.0.0.1"
  - "localhost"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $MASTER_IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
  name: master
  kubeletExtraArgs:
    node-ip: "$MASTER_IP"
EOF
  show_file "$MANIFESTS_DIR/kubeadm-init.yaml"

  step "Pre-pull kubeadm images"
  sudo kubeadm config images pull --kubernetes-version="$K8S_VERSION_FULL" 2>&1 \
    | tee "$LOGS_DIR/kubeadm-images-pull.log"

  step "kubeadm init (skipping kube-proxy addon - Cilium will replace it)"
  sudo kubeadm init \
    --config="$MANIFESTS_DIR/kubeadm-init.yaml" \
    --skip-phases=addon/kube-proxy \
    --ignore-preflight-errors=SystemVerification \
    2>&1 | tee "$LOGS_DIR/kubeadm-init.log"

  step "User kubeconfig"
  mkdir -p "$HOME/.kube"
  sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  kubectl get nodes -o wide
  kubectl -n kube-system get pods
  pause
}

# -----------------------------------------------------------------------------
# Phase 6: Join workers + untaint master
# -----------------------------------------------------------------------------
kubeadm_join() {
  section "Phase 6: kubeadm join workers and untaint master"

  step "Generate join command"
  local join_cmd
  join_cmd=$(sudo kubeadm token create --print-join-command)
  info "join cmd: $join_cmd"
  echo "$join_cmd" > "$LAB_DIR/join.sh"

  for w in "${WORKERS[@]}"; do
    local wname="$(w_name "$w")" wip="$(w_ip "$w")"
    step "Joining $wname ($wip)"
    ssh_w "$wip" "
      sudo $join_cmd \
        --node-name $wname \
        --cri-socket unix:///run/containerd/containerd.sock \
        --ignore-preflight-errors=SystemVerification
    " 2>&1 | tee "$LOGS_DIR/join-$wname.log"
    success "$wname joined"
  done

  step "Untaint master so pods can schedule there too"
  kubectl taint nodes master node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || \
    info "master already untainted"

  step "Node list"
  sleep 3
  kubectl get nodes -o wide
  pause
}

# -----------------------------------------------------------------------------
# Phase 7: Install Cilium
# -----------------------------------------------------------------------------
install_cilium() {
  section "Phase 7: Install Cilium $CILIUM_VERSION"

  if ! helm repo list 2>/dev/null | grep -q '^cilium'; then
    helm repo add cilium https://helm.cilium.io/
  fi
  helm repo update cilium >/dev/null

  cat > "$MANIFESTS_DIR/cilium-values.yaml" <<EOF
# Cilium $CILIUM_VERSION on K8s $K8S_MINOR
# - VXLAN tunnel overlay (pod CIDRs stay inside the cluster)
# - Full kube-proxy replacement (kubeadm skipped the addon)
# - BGP control plane enabled for node-to-node VIP advertisement
# - Data plane bound to ens4 (fabric side)

routingMode: tunnel
tunnelProtocol: vxlan

kubeProxyReplacement: true
k8sServiceHost: $MASTER_IP
k8sServicePort: 6443

ipam:
  mode: kubernetes

devices: "ens4"

bgpControlPlane:
  enabled: true

# Required for Cilium BGP to listen on port 179 (privileged port).
# Without this, GoBGP fails to bind and sessions never establish.
# Full default list + NET_BIND_SERVICE appended.
securityContext:
  capabilities:
    ciliumAgent:
      - CHOWN
      - KILL
      - NET_ADMIN
      - NET_RAW
      - IPC_LOCK
      - SYS_MODULE
      - SYS_ADMIN
      - SYS_RESOURCE
      - DAC_OVERRIDE
      - FOWNER
      - SETGID
      - SETUID
      - NET_BIND_SERVICE

operator:
  replicas: 1

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: false
EOF
  show_file "$MANIFESTS_DIR/cilium-values.yaml"

  step "helm install cilium"
  helm install cilium cilium/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    -f "$MANIFESTS_DIR/cilium-values.yaml" \
    2>&1 | tee "$LOGS_DIR/cilium-install.log"

  step "Wait for Cilium DS ready"
  kubectl -n kube-system rollout status ds/cilium --timeout=5m
  kubectl -n kube-system get pods -l k8s-app=cilium -o wide

  step "Cilium status (brief)"
  kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief || true

  pause
}

# -----------------------------------------------------------------------------
# Phase 8: Cilium BGP (node-to-node full-mesh eBGP)
# -----------------------------------------------------------------------------
configure_bgp() {
  section "Phase 8: Cilium BGP - node-to-node full-mesh eBGP"

  # LoadBalancer IP pool
  cat > "$MANIFESTS_DIR/lb-pool.yaml" <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: ai-vip-pool
spec:
  blocks:
  - cidr: $VIP_POOL_CIDR
EOF
  show_file "$MANIFESTS_DIR/lb-pool.yaml"
  kubectl apply -f "$MANIFESTS_DIR/lb-pool.yaml"

  # Shared peer config
  cat > "$MANIFESTS_DIR/bgp-peer-config.yaml" <<EOF
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
  show_file "$MANIFESTS_DIR/bgp-peer-config.yaml"
  kubectl apply -f "$MANIFESTS_DIR/bgp-peer-config.yaml"

  # Advertisement selector - services labeled bgp-announce=true get their LB IP announced
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
    selector:
      matchLabels:
        bgp-announce: "true"
EOF
  show_file "$MANIFESTS_DIR/bgp-advertisement.yaml"
  kubectl apply -f "$MANIFESTS_DIR/bgp-advertisement.yaml"

  # Per-node ClusterConfig (each node peers with the other three)
  local all_nodes="master worker-1 worker-2 worker-3"
  declare -A NODE_ASN NODE_IP
  NODE_ASN[master]="$MASTER_ASN";          NODE_IP[master]="$MASTER_IP"
  for w in "${WORKERS[@]}"; do
    NODE_ASN["$(w_name "$w")"]="$(w_asn "$w")"
    NODE_IP["$(w_name "$w")"]="$(w_ip "$w")"
  done

  local out="$MANIFESTS_DIR/bgp-cluster-configs.yaml"
  : > "$out"
  echo "# 4 CiliumBGPClusterConfig objects, one per node." >> "$out"
  echo "# Each node selects itself by kubernetes.io/hostname and peers with the other 3." >> "$out"
  echo "# Full-mesh eBGP, 6 sessions total." >> "$out"

  for node in $all_nodes; do
    local node_asn="${NODE_ASN[$node]}"
    {
      echo "---"
      echo "apiVersion: cilium.io/v2alpha1"
      echo "kind: CiliumBGPClusterConfig"
      echo "metadata:"
      echo "  name: bgp-$node"
      echo "spec:"
      echo "  nodeSelector:"
      echo "    matchLabels:"
      echo "      kubernetes.io/hostname: $node"
      echo "  bgpInstances:"
      echo "  - name: instance-$node"
      echo "    localASN: $node_asn"
      echo "    localPort: 179"
      echo "    peers:"
    } >> "$out"
    for peer in $all_nodes; do
      [[ "$peer" == "$node" ]] && continue
      local peer_asn="${NODE_ASN[$peer]}" peer_ip="${NODE_IP[$peer]}"
      {
        echo "    - name: peer-$peer"
        echo "      peerASN: $peer_asn"
        echo "      peerAddress: $peer_ip"
        echo "      peerConfigRef:"
        echo "        name: cluster-peer"
      } >> "$out"
    done
  done

  show_file "$out"
  kubectl apply -f "$out"

  step "Waiting 20s for BGP sessions to establish"
  sleep 20

  step "BGP peer state per node"
  for node in $all_nodes; do
    local pod; pod="$(cilium_pod_on "$node")"
    [[ -z "$pod" ]] && { warn "no cilium pod on $node"; continue; }
    printf "\n  %s%s%s\n" "$BOLD" "=== $node ===" "$NC" >&2
    kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg bgp peers 2>&1 | sed 's/^/    /' >&2 || true
  done
  pause
}

# -----------------------------------------------------------------------------
# Phase 9: Deploy AI training workloads
# -----------------------------------------------------------------------------
deploy_workloads() {
  section "Phase 9: Deploy AI training-style services"

  cat > "$MANIFESTS_DIR/ai-workloads.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ai-training
  labels:
    purpose: poc
---
# --- Parameter Server ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: param-server
  namespace: ai-training
spec:
  replicas: 3
  selector:
    matchLabels: {app: param-server}
  template:
    metadata:
      labels: {app: param-server, role: ai-training}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector: {matchLabels: {app: param-server}}
      containers:
      - name: app
        image: hashicorp/http-echo:1.0
        args: ["-listen=:8080","-text=param-server: gradients synced"]
        ports: [{containerPort: 8080}]
        resources: {requests: {cpu: 50m, memory: 32Mi}}
---
apiVersion: v1
kind: Service
metadata:
  name: param-server
  namespace: ai-training
  labels: {bgp-announce: "true"}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: {app: param-server}
  ports: [{port: 80, targetPort: 8080, name: http}]
---
# --- Trainer ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trainer
  namespace: ai-training
spec:
  replicas: 4
  selector:
    matchLabels: {app: trainer}
  template:
    metadata:
      labels: {app: trainer, role: ai-training}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector: {matchLabels: {app: trainer}}
      containers:
      - name: app
        image: hashicorp/http-echo:1.0
        args: ["-listen=:8080","-text=trainer: epoch=42 loss=0.023"]
        ports: [{containerPort: 8080}]
        resources: {requests: {cpu: 50m, memory: 32Mi}}
---
apiVersion: v1
kind: Service
metadata:
  name: trainer
  namespace: ai-training
  labels: {bgp-announce: "true"}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: {app: trainer}
  ports: [{port: 80, targetPort: 8080}]
---
# --- Inference ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference
  namespace: ai-training
spec:
  replicas: 2
  selector:
    matchLabels: {app: inference}
  template:
    metadata:
      labels: {app: inference, role: ai-training}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector: {matchLabels: {app: inference}}
      containers:
      - name: app
        image: hashicorp/http-echo:1.0
        args: ["-listen=:8080","-text=inference: tps=1240 p99=12ms"]
        ports: [{containerPort: 8080}]
        resources: {requests: {cpu: 50m, memory: 32Mi}}
---
apiVersion: v1
kind: Service
metadata:
  name: inference
  namespace: ai-training
  labels: {bgp-announce: "true"}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: {app: inference}
  ports: [{port: 80, targetPort: 8080}]
---
# --- Data Loader ---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: data-loader
  namespace: ai-training
spec:
  replicas: 3
  selector:
    matchLabels: {app: data-loader}
  template:
    metadata:
      labels: {app: data-loader, role: ai-training}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: ScheduleAnyway
        labelSelector: {matchLabels: {app: data-loader}}
      containers:
      - name: app
        image: hashicorp/http-echo:1.0
        args: ["-listen=:8080","-text=data-loader: batch=256 shards=32"]
        ports: [{containerPort: 8080}]
        resources: {requests: {cpu: 50m, memory: 32Mi}}
---
apiVersion: v1
kind: Service
metadata:
  name: data-loader
  namespace: ai-training
  labels: {bgp-announce: "true"}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: {app: data-loader}
  ports: [{port: 80, targetPort: 8080}]
EOF
  show_file "$MANIFESTS_DIR/ai-workloads.yaml"
  kubectl apply -f "$MANIFESTS_DIR/ai-workloads.yaml"

  step "Wait for deployments"
  kubectl -n ai-training wait --for=condition=Available deployment --all --timeout=3m || true

  step "Pod distribution"
  kubectl -n ai-training get pods -o wide | tee "$LOGS_DIR/pod-distribution.log"

  step "Services (VIPs)"
  kubectl -n ai-training get svc -o wide | tee "$LOGS_DIR/services.log"
  pause
}

# -----------------------------------------------------------------------------
# Phase 10: Verification
# -----------------------------------------------------------------------------
verify() {
  section "Phase 10: Verification"

  step "BGP routes advertised from every node"
  for node in master worker-1 worker-2 worker-3; do
    local pod; pod="$(cilium_pod_on "$node")"
    [[ -z "$pod" ]] && continue
    printf "\n  %s%s%s\n" "$BOLD" "--- $node: advertised ---" "$NC" >&2
    kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg bgp routes advertised ipv4 unicast 2>&1 \
      | sed 's/^/    /' >&2 || true
  done

  step "BGP routes received from peers (node: master)"
  local pod; pod="$(cilium_pod_on master)"
  kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg bgp routes received ipv4 unicast 2>&1 \
    | sed 's/^/  /' >&2 || true

  step "Kernel FIB on master - VIP /32s installed?"
  ip route | grep -E "192\.168\.100\." | sed 's/^/  /' >&2 \
    || warn "no VIP routes in master kernel FIB"

  step "Cilium service list (master) - VIPs -> backends"
  kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg service list \
    | grep -E "192\.168\.100\.|Service|---" | head -30 | sed 's/^/  /' >&2 || true

  pause
}

# -----------------------------------------------------------------------------
# Phase 11: Marquee traffic tests
# -----------------------------------------------------------------------------
marquee_test() {
  section "Phase 11: Marquee traffic tests"

  step "Collect all VIPs"
  local vips
  vips=$(kubectl -n ai-training get svc \
    -o jsonpath='{range .items[*]}{.metadata.name}={.status.loadBalancer.ingress[0].ip}{"\n"}{end}' \
    | { grep -v '=$' || true; })
  if [[ -z "$vips" ]]; then
    warn "no VIPs allocated yet; skipping marquee"
    return 1
  fi
  echo "$vips" | sed 's/^/  /' >&2

  step "Test 1: curl each VIP from master host netns (eBPF LB + VXLAN to backend)"
  echo "$vips" | while IFS='=' read -r svc vip; do
    [[ -z "$svc" || -z "$vip" ]] && continue
    printf "\n  %s>>> %s @ %s%s\n" "$BOLD$GREEN" "$svc" "$vip" "$NC" >&2
    for i in 1 2 3; do
      curl -s --max-time 5 "http://$vip/" && echo "" || warn "attempt $i failed"
    done
  done | tee "$LOGS_DIR/marquee-master.log"

  step "Test 2: deploy a curl pod on worker-1, curl every VIP from there"
  cat > "$MANIFESTS_DIR/test-client.yaml" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-client
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep","3600"]
  restartPolicy: Never
EOF
  kubectl apply -f "$MANIFESTS_DIR/test-client.yaml"
  kubectl wait --for=condition=Ready pod/test-client --timeout=90s

  echo "$vips" | while IFS='=' read -r svc vip; do
    [[ -z "$svc" || -z "$vip" ]] && continue
    printf "\n  %s>>> from worker-1 pod -> %s @ %s%s\n" "$BOLD$GREEN" "$svc" "$vip" "$NC" >&2
    kubectl exec test-client -- curl -s --max-time 5 "http://$vip/" && echo "" || warn "failed"
  done | tee "$LOGS_DIR/marquee-pod.log"

  step "Test 3: pod-to-pod across the fabric (VXLAN over ens4)"
  local target_pod_ip target_node
  target_node=$(kubectl -n ai-training get pod -l app=trainer \
    -o jsonpath='{range .items[?(@.spec.nodeName=="worker-3")]}{.status.podIP}={.spec.nodeName}{"\n"}{end}' \
    | head -1)
  target_pod_ip="${target_node%%=*}"
  if [[ -n "$target_pod_ip" ]]; then
    info "Target: trainer pod on worker-3 @ $target_pod_ip"
    info "Source: test-client on worker-1"
    kubectl exec test-client -- curl -s --max-time 5 "http://$target_pod_ip:8080/" \
      | tee "$LOGS_DIR/pod-to-pod-vxlan.log" && echo ""
  else
    warn "no trainer pod on worker-3 (probably scheduled elsewhere); skipping test-3"
  fi

  step "Cleanup test pod"
  kubectl delete pod test-client --wait=false 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
summary() {
  section "Summary"
  cat >&2 <<EOF

  Lab is up.

  Cluster:
    master    $MASTER_IP   AS $MASTER_ASN  (control plane + worker, untainted)
    worker-1  $(w_ip "$WORKER_1")   AS $(w_asn "$WORKER_1")
    worker-2  $(w_ip "$WORKER_2")   AS $(w_asn "$WORKER_2")
    worker-3  $(w_ip "$WORKER_3")   AS $(w_asn "$WORKER_3")

  Networking:
    Pod CIDR   $POD_CIDR    (VXLAN overlay, stays in cluster)
    Svc CIDR   $SVC_CIDR
    VIP pool   $VIP_POOL_CIDR (advertised node-to-node via BGP)
    Cilium     $CILIUM_VERSION, kube-proxy replaced, device=ens4

  Inspection commands:
    kubectl get nodes -o wide
    kubectl -n ai-training get svc,pods -o wide
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bgp peers
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bgp routes advertised ipv4 unicast
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list

  Quick curl:
    kubectl -n ai-training get svc -o wide
    curl http://<VIP>/

  Artifacts:
    $LAB_DIR

  Tear down:
    $(basename "$0") --cleanup

EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  check_prereqs
  setup_dirs
  setup_hosts_file
  system_prep
  setup_kubelet_node_ip
  kubeadm_init
  kubeadm_join
  install_cilium
  configure_bgp
  deploy_workloads
  verify
  marquee_test || warn "marquee test had issues; inspect logs in $LOGS_DIR"
  summary
}

main "$@"
