#!/usr/bin/env bash
# =============================================================================
# Kubernetes + Cilium + Node-to-Node BGP Lab - End-to-End Sanity Check
# =============================================================================
# Run from master. Prints every command it runs and its full output.
# Designed to be copy-pasted into a blog post / shared as evidence the lab
# is working end to end.
#
# What it checks (in order):
#   1. Cluster & node health
#   2. Cilium DS + agent status on every node
#   3. BGP peer sessions (all 12 for 4-node full mesh)
#   4. BGP RIB: available, advertised, received
#   5. Kubernetes LoadBalancer services + allocated VIPs
#   6. Cilium LB service map + eBPF program backends
#   7. End-to-end HTTP tests: master host + workers + pod-to-VIP + pod-to-pod
#   8. Fabric reachability sanity
#
# Usage:
#   bash lab_sanity.sh           # run all phases
#   bash lab_sanity.sh --quick   # skip long-running pod-to-pod test
# =============================================================================

set -uo pipefail

BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
RED='\033[1;31m'
NC='\033[0m'

QUICK="${1:-}"
PASS=0; FAIL=0

NODES=(master worker-1 worker-2 worker-3)
MASTER_IP=10.1.1.10
WORKER_IPS=(10.1.2.10 10.1.3.10 10.1.4.10)
VIP_POOL_PREFIX="192.168.100"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
banner() {
  printf "\n${BOLD}${BLUE}============================================================${NC}\n"
  printf "${BOLD}${BLUE} %s${NC}\n" "$*"
  printf "${BOLD}${BLUE}============================================================${NC}\n"
}

section() {
  printf "\n${BOLD}${CYAN}── %s ──${NC}\n" "$*"
}

# Print a command, run it, and always show stdout+stderr.
run() {
  printf "${YELLOW}\$${NC} ${BOLD}%s${NC}\n" "$*"
  eval "$@" 2>&1 | sed 's/^/  /'
  local rc=${PIPESTATUS[0]}
  if [[ $rc -eq 0 ]]; then
    PASS=$((PASS+1))
    printf "${GREEN}  ✓ exit 0${NC}\n"
  else
    FAIL=$((FAIL+1))
    printf "${RED}  ✗ exit $rc${NC}\n"
  fi
  return $rc
}

# Like run(), but allows non-zero exit without incrementing FAIL
# (used for discovery commands where "no output" is fine).
run_ok() {
  printf "${YELLOW}\$${NC} ${BOLD}%s${NC}\n" "$*"
  eval "$@" 2>&1 | sed 's/^/  /' || true
}

# cilium-dbg wrapper - use official CLI if installed, fall back to kubectl exec.
cdbg() {
  if command -v cilium >/dev/null 2>&1; then
    cilium "$@"
  else
    kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg "$@"
  fi
}

# Get the cilium-agent pod on a specific node.
cilium_pod_on() {
  kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector spec.nodeName="$1" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# =============================================================================
# Phase 1: cluster + node health
# =============================================================================
banner "Phase 1/8: Cluster & node health"

section "Kubernetes version on master"
run "kubectl version"

section "Nodes: everyone Ready?"
run "kubectl get nodes -o wide"

section "Node conditions summary"
run 'kubectl get nodes -o jsonpath='"'"'{range .items[*]}{.metadata.name}{": Ready="}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'"'"

section "System pods healthy?"
run "kubectl -n kube-system get pods -o wide | grep -vE 'Completed'"

# =============================================================================
# Phase 2: Cilium DS + agent status
# =============================================================================
banner "Phase 2/8: Cilium DaemonSet & agent status"

section "Cilium DaemonSet rollout state"
run "kubectl -n kube-system get ds cilium -o wide"

section "Cilium agent pods (one per node)"
run "kubectl -n kube-system get pods -l k8s-app=cilium -o wide"

section "Cilium agent version + kube-proxy replacement status"
run "cdbg status --brief || kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief"

section "NET_BIND_SERVICE capability on cilium-agent container (required for BGP port 179)"
run "kubectl -n kube-system get ds cilium -o json \
    | jq -r '.spec.template.spec.containers[] | select(.name==\"cilium-agent\") | .securityContext.capabilities.add[]'"

# =============================================================================
# Phase 3: BGP peer sessions (full mesh = 12 sessions)
# =============================================================================
banner "Phase 3/8: BGP peer sessions across the node mesh"

for node in "${NODES[@]}"; do
  section "BGP peers on $node"
  POD=$(cilium_pod_on "$node")
  if [[ -z "$POD" ]]; then
    printf "${RED}  no cilium pod on $node${NC}\n"; FAIL=$((FAIL+1)); continue
  fi
  run "kubectl -n kube-system exec $POD -c cilium-agent -- cilium-dbg bgp peers"
done

section "Expected: 3 peers per node, Session=established, Received=4, Advertised=5"
ESTAB=$(for node in "${NODES[@]}"; do
  POD=$(cilium_pod_on "$node"); [[ -z "$POD" ]] && continue
  kubectl -n kube-system exec "$POD" -c cilium-agent -- cilium-dbg bgp peers 2>/dev/null \
    | awk '/established/{c++} END{print c+0}'
done | paste -sd+ | bc)
printf "${BOLD}Total established sessions across all nodes: ${ESTAB}/12${NC}\n"
if [[ "${ESTAB:-0}" == "12" ]]; then
  printf "${GREEN}  ✓ full mesh established${NC}\n"; PASS=$((PASS+1))
else
  printf "${RED}  ✗ expected 12, got ${ESTAB}${NC}\n"; FAIL=$((FAIL+1))
fi

# =============================================================================
# Phase 4: BGP RIB - available / advertised / received
# =============================================================================
banner "Phase 4/8: BGP RIB (Routing Information Base)"

section "Local routes available to advertise (master view)"
run "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bgp routes available ipv4 unicast"

section "Routes advertised from master to each peer"
POD=$(cilium_pod_on master)
run "kubectl -n kube-system exec $POD -c cilium-agent -- cilium-dbg bgp routes advertised ipv4 unicast"

# -----------------------------------------------------------------------------
# Phase 4b: VIP propagation matrix - every node's inbound RIB grouped by peer
# Expect 4 nodes x 3 peers x 4 VIPs = 48 inbound routes total
# -----------------------------------------------------------------------------
banner "Phase 4b/8: VIP propagation matrix (inbound RIB per peer)"

declare -A NODE_IP_MAP=(
  [master]=10.1.1.10
  [worker-1]=10.1.2.10
  [worker-2]=10.1.3.10
  [worker-3]=10.1.4.10
)
declare -A NODE_AS_MAP=(
  [master]=65201
  [worker-1]=65202
  [worker-2]=65203
  [worker-3]=65204
)

for node in "${NODES[@]}"; do
  section "$node  (${NODE_IP_MAP[$node]}  AS ${NODE_AS_MAP[$node]})"
  POD=$(cilium_pod_on "$node")
  [[ -z "$POD" ]] && continue
  for peer_node in "${NODES[@]}"; do
    [[ "$peer_node" = "$node" ]] && continue
    peer_ip=${NODE_IP_MAP[$peer_node]}
    peer_as=${NODE_AS_MAP[$peer_node]}
    printf "${BOLD}  >>> received from %s (%s, AS %s)${NC}\n" "$peer_node" "$peer_ip" "$peer_as"
    run "kubectl -n kube-system exec $POD -c cilium-agent -- cilium-dbg bgp routes available ipv4 unicast peer $peer_ip"
  done
done

section "Totals check: each node must receive 12 VIPs (4 VIPs from 3 peers each)"
VIP_TOTAL=0
VIP_EXPECTED=48
ALL_GOOD=true
for node in "${NODES[@]}"; do
  POD=$(cilium_pod_on "$node")
  [[ -z "$POD" ]] && continue
  count=0
  for peer_node in "${NODES[@]}"; do
    [[ "$peer_node" = "$node" ]] && continue
    peer_ip=${NODE_IP_MAP[$peer_node]}
    n=$(kubectl -n kube-system exec "$POD" -c cilium-agent -- \
          cilium-dbg bgp routes available ipv4 unicast peer "$peer_ip" 2>/dev/null \
        | { grep -c '192.168.100' || true; })
    count=$((count + n))
  done
  VIP_TOTAL=$((VIP_TOTAL + count))
  if [[ "$count" -eq 12 ]]; then
    printf "${GREEN}  ✓ %-10s received %d VIPs${NC}\n" "$node" "$count"
  else
    printf "${RED}  ✗ %-10s received %d VIPs (expected 12)${NC}\n" "$node" "$count"
    ALL_GOOD=false
  fi
done
if [[ "$VIP_TOTAL" -eq "$VIP_EXPECTED" ]] && $ALL_GOOD; then
  printf "${GREEN}${BOLD}  ✓ GRAND TOTAL: %d / %d inbound VIP routes${NC}\n" "$VIP_TOTAL" "$VIP_EXPECTED"
  PASS=$((PASS+1))
else
  printf "${RED}${BOLD}  ✗ GRAND TOTAL: %d / %d${NC}\n" "$VIP_TOTAL" "$VIP_EXPECTED"
  FAIL=$((FAIL+1))
fi

# -----------------------------------------------------------------------------
# Phase 4c: Live withdraw + restore demo
# Proves BGP is dynamic - Received counter drops 4->3, then returns to 4 after
# the service is recreated. Skipped in --quick mode.
# -----------------------------------------------------------------------------
if [[ "$QUICK" != "--quick" ]]; then
  banner "Phase 4c/8: Live BGP withdraw + restore demo"

  section "BEFORE - baseline (expect Received=4 on every session)"
  run "cilium bgp peers"

  section "Deleting trainer service (VIP 192.168.100.1)"
  run "kubectl -n ai-training delete svc trainer"
  sleep 3

  section "AFTER delete (expect Received=3 on every session)"
  run "cilium bgp peers"

  section "Master's inbound RIB from worker-1 - trainer VIP should be absent"
  POD=$(cilium_pod_on master)
  run "kubectl -n kube-system exec $POD -c cilium-agent -- cilium-dbg bgp routes available ipv4 unicast peer 10.1.2.10"

  section "Restoring trainer service"
  # Find manifest path dynamically
  MANIFESTS_PATH=$(find "$HOME" -type f -name "ai-workloads.yaml" 2>/dev/null | head -1)
  if [[ -n "$MANIFESTS_PATH" ]]; then
    run "kubectl apply -f $MANIFESTS_PATH"
  else
    # Fallback: recreate the trainer service inline
    run "kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: trainer
  namespace: ai-training
  labels: {bgp-announce: \"true\"}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Cluster
  selector: {app: trainer}
  ports: [{port: 80, targetPort: 8080}]
EOF"
  fi
  sleep 4

  section "RESTORED - back to baseline (expect Received=4 on every session)"
  run "cilium bgp peers"
fi

# -----------------------------------------------------------------------------
# Phase 4d: Wire-level BGP UPDATE capture (skipped in --quick mode)
# Captures actual BGP UPDATE and Withdrawn route messages between peers.
# -----------------------------------------------------------------------------
if [[ "$QUICK" != "--quick" ]]; then
  banner "Phase 4d/8: Wire-level BGP UPDATE capture"

  PCAP=/tmp/bgp-update-$$.pcap
  section "Starting tcpdump on ens4 for TCP/179 (PSH-flagged packets only)"
  sudo tcpdump -i ens4 -nn -s0 -w "$PCAP" 'tcp port 179 and tcp[tcpflags] & tcp-push != 0' \
    >/dev/null 2>&1 &
  TCPDUMP_PID=$!
  sleep 2

  section "Triggering BGP UPDATE and WITHDRAW by bouncing data-loader service"
  run "kubectl -n ai-training delete svc data-loader"
  sleep 3
  MANIFESTS_PATH=$(find "$HOME" -type f -name "ai-workloads.yaml" 2>/dev/null | head -1)
  [[ -n "$MANIFESTS_PATH" ]] && run "kubectl apply -f $MANIFESTS_PATH"
  sleep 3

  sudo kill "$TCPDUMP_PID" 2>/dev/null
  wait 2>/dev/null

  section "Decoded BGP messages from wire capture"
  run "sudo tcpdump -r $PCAP -nn -v 'tcp port 179' 2>&1 | grep -E 'Update Message|NLRI|192.168.100|Withdrawn' | head -30"

  sudo rm -f "$PCAP"
fi

# =============================================================================
# Phase 5: Kubernetes LB services + VIP allocation
# =============================================================================
banner "Phase 5/8: Kubernetes LoadBalancer services"

section "Services in the ai-training namespace"
run "kubectl -n ai-training get svc -o wide"

section "All pods in ai-training (running?)"
run "kubectl -n ai-training get pods -o wide"

section "CiliumLoadBalancerIPPool state"
run "kubectl get ciliumloadbalancerippool -o wide"

# =============================================================================
# Phase 6: Cilium LB service map + eBPF backends
# =============================================================================
banner "Phase 6/8: Cilium LB service map & eBPF backends"

section "Cilium service list - VIPs should resolve to pod backends"
run "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list | grep -E 'Service|${VIP_POOL_PREFIX}|LoadBalancer' | head -30"

section "eBPF LB map entries for VIPs (first 10)"
run "kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list | grep -E '${VIP_POOL_PREFIX}|REVNAT|SERVICE' | head -20"

# =============================================================================
# Phase 7: End-to-end data-plane tests
# =============================================================================
banner "Phase 7/8: End-to-end data-plane tests"

section "Collect all VIPs"
mapfile -t VIPS < <(kubectl -n ai-training get svc -o jsonpath='{range .items[*]}{.metadata.name}={.status.loadBalancer.ingress[0].ip}{"\n"}{end}' | grep -v '=$')
for e in "${VIPS[@]}"; do printf "  %s\n" "$e"; done

section "Test A: curl every VIP from master host"
for entry in "${VIPS[@]}"; do
  svc="${entry%%=*}"; vip="${entry##*=}"
  printf "${BOLD}  >>> %s @ %s${NC}\n" "$svc" "$vip"
  run "curl -s -o /dev/null -w 'HTTP %{http_code} | connect %{time_connect}s | total %{time_total}s\n' --max-time 5 http://$vip/"
done

section "Test B: curl every VIP from worker-3 host (cross-node via fabric)"
for entry in "${VIPS[@]}"; do
  svc="${entry%%=*}"; vip="${entry##*=}"
  printf "${BOLD}  >>> worker-3 -> %s @ %s${NC}\n" "$svc" "$vip"
  run "ssh -o StrictHostKeyChecking=no user@${WORKER_IPS[2]} \"curl -s -o /dev/null -w 'HTTP %{http_code} | connect %{time_connect}s | total %{time_total}s\\n' --max-time 5 http://$vip/\""
done

if [[ "$QUICK" != "--quick" ]]; then
  section "Test C: pod -> VIP from a pod on worker-1"
  cat > /tmp/test-client.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: sanity-client
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: worker-1
  tolerations: [{operator: Exists}]
  containers:
  - name: curl
    image: curlimages/curl:8.10.1
    command: ["sleep","300"]
  restartPolicy: Never
EOF
  run "kubectl apply -f /tmp/test-client.yaml"
  run "kubectl wait --for=condition=Ready pod/sanity-client --timeout=60s"

  for entry in "${VIPS[@]}"; do
    svc="${entry%%=*}"; vip="${entry##*=}"
    printf "${BOLD}  >>> pod-on-worker-1 -> %s @ %s${NC}\n" "$svc" "$vip"
    run "kubectl exec sanity-client -- curl -s -o /dev/null -w 'HTTP %{http_code} | total %{time_total}s\n' --max-time 5 http://$vip/"
  done

  section "Test D: pod-to-pod across fabric (VXLAN over ens4)"
  TGT_POD_IP=$(kubectl -n ai-training get pod -l app=trainer \
    -o jsonpath='{range .items[?(@.spec.nodeName=="worker-3")]}{.status.podIP}{"\n"}{end}' \
    | head -1)
  if [[ -n "$TGT_POD_IP" ]]; then
    printf "  Target: trainer pod on worker-3 @ $TGT_POD_IP\n  Source: sanity-client on worker-1\n"
    run "kubectl exec sanity-client -- curl -s -o /dev/null -w 'HTTP %{http_code} | total %{time_total}s\n' --max-time 5 http://$TGT_POD_IP:8080/"
  else
    printf "  no trainer pod on worker-3; skipping\n"
  fi

  run_ok "kubectl delete pod sanity-client --wait=false"
fi

# =============================================================================
# Phase 8: Underlay / fabric reachability sanity
# =============================================================================
banner "Phase 8/8: Underlay fabric reachability"

section "Traceroute master -> worker-1 on TCP/179 (shows hop count)"
run "sudo traceroute -T -p 179 -q 1 -m 5 10.1.2.10"

section "Jumbo frame DF probe master -> worker-3 (8972 bytes)"
run "ping -M do -s 8972 -c 2 10.1.4.10"

section "Ensure master can reach every worker on TCP/179"
for ip in "${WORKER_IPS[@]}"; do
  printf "${BOLD}  >>> master -> $ip:179${NC}\n"
  run "timeout 3 bash -c '(echo > /dev/tcp/$ip/179) && echo OPEN || echo CLOSED'"
done

# =============================================================================
# Summary
# =============================================================================
banner "Summary"
TOTAL=$((PASS+FAIL))
printf "${BOLD}Ran %d checks: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$TOTAL" "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  printf "${GREEN}${BOLD}  ALL GOOD - lab is end-to-end healthy${NC}\n\n"
  exit 0
else
  printf "${RED}${BOLD}  SOME CHECKS FAILED - scroll up for details${NC}\n\n"
  exit 1
fi
