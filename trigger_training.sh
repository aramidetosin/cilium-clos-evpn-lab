#!/usr/bin/env bash
# =============================================================================
# trigger_training.sh  —  run from the frontend
# -----------------------------------------------------------------------------
# Simulates kicking off an AI training job against the ai-training namespace's
# four LoadBalancer VIPs. The workflow mimics a real ML pipeline:
#
#   1. Preflight        — health-check all services before committing
#   2. Data loader      — fetch N training batches (sequential)
#   3. Param server     — initialize shared parameters
#   4. Training loop    — EPOCHS × BATCHES × WORKERS (parallel) training steps
#                         with periodic param-server sync + end-of-epoch
#                         inference-tier validation
#   5. Deploy           — final checkpoint to inference tier
#   6. Summary          — per-service latency stats + fabric path summary
#
# The backends just echo static strings, but the shape of the workflow (phase
# ordering, parallel workers, sustained load) makes this a legitimate end-to-end
# stress test of the whole data path:
#   frontend → Leaf-N fabric edge → leaf SVI → K8s node → Cilium BPF → pod
#
# Tunables (all envvars, all optional):
#   EPOCHS=3               number of training epochs
#   BATCHES_PER_EPOCH=8    training batches per epoch
#   WORKERS=4              parallel curl workers per training batch
#   PARAM_SYNC_EVERY=4     run param-server sync every N batches
#   CURL_TIMEOUT=5         per-request timeout (seconds)
#   MODEL=llama-7b         just cosmetic, shown in the top banner
#
# Usage:
#   ./trigger_training.sh
#   WORKERS=8 EPOCHS=5 ./trigger_training.sh
# =============================================================================

set -uo pipefail

# ---- tunables ---------------------------------------------------------------
readonly EPOCHS="${EPOCHS:-3}"
readonly BATCHES_PER_EPOCH="${BATCHES_PER_EPOCH:-8}"
readonly WORKERS="${WORKERS:-4}"
readonly PARAM_SYNC_EVERY="${PARAM_SYNC_EVERY:-4}"
readonly CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
readonly MODEL="${MODEL:-llama-7b}"
readonly JOB_ID="job-$(date +%s)-$RANDOM"

# ---- VIP map ----------------------------------------------------------------
# service_name → VIP (on ai-training namespace)
readonly -A VIPS=(
  ["param-server"]="192.168.100.0"
  ["trainer"]="192.168.100.1"
  ["inference"]="192.168.100.2"
  ["data-loader"]="192.168.100.3"
)

# ---- state ------------------------------------------------------------------
readonly TMPDIR=$(mktemp -d -t training.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
START_NS=$(date +%s%N)

# ---- display ----------------------------------------------------------------
BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'

banner() {
  printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$BOLD$MAGENTA" "$NC"
  printf "  %s%s%s\n"                                                       "$BOLD$MAGENTA" "$*" "$NC"
  printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n"   "$BOLD$MAGENTA" "$NC"
}
phase()   { printf "\n%s[%s]%s %s\n" "$BOLD$CYAN" "$1" "$NC" "$2"; }

# ---- core request function -------------------------------------------------
# Synchronous HTTP GET to a VIP. Logs latency+status for aggregation later.
# Emits a one-line result to stdout with response body and ms latency.
hit() {
  local svc="$1" label="${2:-$svc}" vip="${VIPS[$svc]}"
  local body_file="$TMPDIR/_body_$$_$RANDOM"
  local meta http_code time_s ms body

  meta=$(curl -s -o "$body_file" -w "%{http_code}:%{time_total}" \
         --max-time "$CURL_TIMEOUT" "http://$vip/" 2>&1) || true
  http_code="${meta%%:*}"
  time_s="${meta##*:}"
  ms=$(awk -v t="$time_s" 'BEGIN { printf "%.0f", t*1000 }')
  body=$(tr -d '\n\r' < "$body_file" 2>/dev/null || echo "")
  rm -f "$body_file"

  if [[ "$http_code" == "200" ]]; then
    echo "$ms" >> "$TMPDIR/lat.$svc"
    echo "OK"  >> "$TMPDIR/all.log"
    printf "${GREEN}✓${NC} %-20s ${DIM}%4sms${NC}  %s\n" "$label" "$ms" "$body"
    return 0
  else
    echo "FAIL" >> "$TMPDIR/all.log"
    printf "${RED}✗${NC} %-20s ${DIM}%4sms${NC}  HTTP %s\n" "$label" "${ms:-?}" "${http_code:-timeout}"
    return 1
  fi
}

# Parallel version: run N workers concurrently against a service.
# Captures each worker's output to a file, then prints in order.
parallel_hit() {
  local svc="$1" count="$2" label_prefix="${3:-worker}"
  local pids=() i
  for i in $(seq 1 "$count"); do
    ( hit "$svc" "${label_prefix}-$i" > "$TMPDIR/_par_$i" ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
  for i in $(seq 1 "$count"); do
    printf "      "; cat "$TMPDIR/_par_$i" 2>/dev/null
    rm -f "$TMPDIR/_par_$i"
  done
}

# ---- phase 1: preflight -----------------------------------------------------
phase_preflight() {
  phase preflight "Validating service endpoints (all VIPs must respond)"
  local ok=0
  for svc in param-server trainer inference data-loader; do
    printf "    "
    hit "$svc" "$svc" && ok=$((ok+1))
  done
  if [[ $ok -lt 4 ]]; then
    printf "\n  ${RED}✗ Preflight failed — %d/4 services reachable. Aborting.${NC}\n" "$ok"
    printf "  ${DIM}Check fabric path: 'ip route get 192.168.100.0' and 'ping 192.168.255.1'${NC}\n"
    exit 1
  fi
  printf "\n  ${GREEN}✓${NC} All 4 services healthy, proceeding with training.\n"
}

# ---- phase 2: load training data -------------------------------------------
phase_load_data() {
  phase data-loader "Streaming training shards ($BATCHES_PER_EPOCH batches)"
  for i in $(seq 1 "$BATCHES_PER_EPOCH"); do
    printf "    "
    hit data-loader "batch $i/$BATCHES_PER_EPOCH"
  done
}

# ---- phase 3: init param server --------------------------------------------
phase_init_params() {
  phase param-server "Initializing shared parameters"
  printf "    "
  hit param-server "init-weights"
}

# ---- phase 4: training loop (the heavy lifter) -----------------------------
phase_train_epoch() {
  local epoch="$1"
  phase "epoch $epoch/$EPOCHS" \
        "Training — $BATCHES_PER_EPOCH steps × $WORKERS workers (parallel)"

  for batch in $(seq 1 "$BATCHES_PER_EPOCH"); do
    printf "    ${DIM}step %d/%d:${NC}\n" "$batch" "$BATCHES_PER_EPOCH"
    parallel_hit trainer "$WORKERS" "w"

    # Periodic param-server sync — simulates gradient aggregation
    if (( batch % PARAM_SYNC_EVERY == 0 )); then
      printf "      ${DIM}↳ gradient sync:${NC} "
      hit param-server "sync@step-$batch"
    fi
  done

  # End-of-epoch validation on inference tier
  printf "    ${DIM}↳ end-of-epoch validation:${NC} "
  hit inference "epoch-$epoch-eval"
}

# ---- phase 5: deploy checkpoint --------------------------------------------
phase_deploy() {
  phase deploy "Promoting checkpoint to inference tier"
  printf "    "
  hit inference "deploy-checkpoint"
}

# ---- phase 6: summary -------------------------------------------------------
phase_summary() {
  local end_ns
  end_ns=$(date +%s%N)
  local elapsed_s
  elapsed_s=$(awk -v s="$START_NS" -v e="$end_ns" 'BEGIN { printf "%.1f", (e-s)/1e9 }')

  local total fails ok_count success_rate
  total=$(wc -l < "$TMPDIR/all.log" 2>/dev/null | tr -d ' ')
  total=${total:-0}
  fails=$(grep -c '^FAIL' "$TMPDIR/all.log" 2>/dev/null | tr -d ' ')
  fails=${fails:-0}
  ok_count=$((total - fails))
  if [[ $total -gt 0 ]]; then
    success_rate=$(awk -v t="$total" -v o="$ok_count" 'BEGIN { printf "%.1f", o*100/t }')
  else
    success_rate="0.0"
  fi

  banner "Training Job Summary  ($JOB_ID)"

  printf "  ${BOLD}Total requests:${NC}       %d\n"               "$total"
  if [[ $fails -eq 0 ]]; then
    printf "  ${BOLD}Successful:${NC}           ${GREEN}%d (%s%%)${NC}\n" "$ok_count" "$success_rate"
    printf "  ${BOLD}Failed:${NC}               ${GREEN}0${NC}\n"
  else
    printf "  ${BOLD}Successful:${NC}           %d (%s%%)\n"      "$ok_count" "$success_rate"
    printf "  ${BOLD}Failed:${NC}               ${RED}%d${NC}\n"  "$fails"
  fi
  printf "  ${BOLD}Wall time:${NC}            %ss\n"              "$elapsed_s"
  local rps
  rps=$(awk -v t="$total" -v s="$elapsed_s" 'BEGIN { if (s>0) printf "%.1f", t/s; else printf "0.0" }')
  printf "  ${BOLD}Throughput:${NC}           %s req/s\n"         "$rps"

  printf "\n  ${BOLD}Per-service latency (ms):${NC}\n"
  printf "    %-16s %8s  %8s  %8s  %8s  %8s\n" "service" "count" "avg" "p50" "p99" "max"
  printf "    %-16s %8s  %8s  %8s  %8s  %8s\n" "────────" "─────" "───" "───" "───" "───"
  for svc in param-server trainer inference data-loader; do
    if [[ -s "$TMPDIR/lat.$svc" ]]; then
      # shellcheck disable=SC2046
      set -- $(sort -n "$TMPDIR/lat.$svc" | awk '
        { a[NR]=$1; s+=$1 }
        END {
          if (NR==0) { print "0 - - - -"; exit }
          i50=int(NR*0.5)+1; if (i50>NR) i50=NR
          i99=int(NR*0.99)+1; if (i99>NR) i99=NR
          printf "%d %.1f %s %s %s", NR, s/NR, a[i50], a[i99], a[NR]
        }')
      printf "    %-16s %8d  %8s  %8s  %8s  %8s\n" "$svc" "$1" "$2" "$3" "$4" "$5"
    else
      printf "    %-16s %8s  %8s  %8s  %8s  %8s\n" "$svc" "0" "-" "-" "-" "-"
    fi
  done

  # Discover what leaf we're on from the kernel route for sanity in output
  local leaf_edge
  leaf_edge=$(ip route get 192.168.100.0 2>/dev/null | awk '/via/ { for(i=1;i<=NF;i++) if ($i=="via") print $(i+1) }')

  printf "\n  ${BOLD}Fabric path exercised:${NC}\n"
  printf "    frontend  ${DIM}(%s)${NC}\n" "$(ip -4 addr show ens4 2>/dev/null | awk '/inet /{print $2; exit}')"
  printf "      ${DIM}│ ens4 static route 192.168.0.0/16${NC}\n"
  printf "    leaf SVI  ${DIM}(%s, VRF tenant-1)${NC}\n" "${leaf_edge:-unknown}"
  printf "      ${DIM}│ VRF tenant-1 FIB lookup → rack-local host eBGP path${NC}\n"
  printf "    K8s host  ${DIM}(receives on ens4, VIP on lo)${NC}\n"
  printf "      ${DIM}│ Cilium kubeProxyReplacement BPF (LB decision)${NC}\n"
  printf "    backend pod  ${DIM}(possibly on any of 4 racks via Cilium overlay)${NC}\n"
  printf "      ${DIM}│ response path: Cilium → host → leaf → (EVPN if cross-rack) → Leaf-edge → frontend${NC}\n"

  echo
  if [[ $fails -eq 0 ]]; then
    printf "  ${BOLD}${GREEN}✓ Training job completed successfully${NC}\n"
    printf "  ${DIM}$ok_count requests × ${elapsed_s}s wall → $rps req/s sustained against all 4 VIPs${NC}\n"
    return 0
  else
    printf "  ${BOLD}${RED}✗ Training job completed with $fails failures${NC}\n"
    printf "  ${DIM}Investigate: check 'ip route show 192.168.0.0/16' and BGP state on leaves${NC}\n"
    return 1
  fi
}

# ---- main -------------------------------------------------------------------
main() {
  banner "AI Training Job — $MODEL fine-tuning"
  printf "  ${BOLD}Job ID:${NC}       %s\n"        "$JOB_ID"
  printf "  ${BOLD}Submitted by:${NC} %s@%s\n"     "${USER:-unknown}" "$(hostname)"
  printf "  ${BOLD}Target:${NC}       ai-training/{param-server, trainer, inference, data-loader}\n"
  printf "  ${BOLD}Plan:${NC}         %d epochs × %d batches × %d workers = %d training steps\n" \
         "$EPOCHS" "$BATCHES_PER_EPOCH" "$WORKERS" "$((EPOCHS * BATCHES_PER_EPOCH * WORKERS))"
  printf "  ${BOLD}Timeout:${NC}      %ss per request\n" "$CURL_TIMEOUT"

  phase_preflight
  phase_load_data
  phase_init_params
  for epoch in $(seq 1 "$EPOCHS"); do
    phase_train_epoch "$epoch"
  done
  phase_deploy
  phase_summary
}

main "$@"
