#!/usr/bin/env bash
# =============================================================================
# trigger_training.sh  —  run from the frontend
# -----------------------------------------------------------------------------
# Simulates kicking off an AI training job against the ai-training namespace's
# four LoadBalancer VIPs and reports:
#
#   - Per-service latency (count / avg / p50 / p99 / max)
#   - Per-request POD LANDING — which backend pod actually served each request
#   - Pod distribution table showing how Cilium's LB spread the load
#
# Pod identity is detected from:
#   1. HTTP response headers  X-Pod-Name / X-Node-Name  (preferred)
#   2. Response body markers  pod=<n> node=<n>          (fallback)
#
# If neither is present, the script still runs but reports "no pod info" —
# run deploy_identity_services.sh on master to enable it.
#
# Tunables (env vars):
#   EPOCHS=3  BATCHES_PER_EPOCH=8  WORKERS=4  PARAM_SYNC_EVERY=4
#   CURL_TIMEOUT=5  MODEL=llama-7b
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
  printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n" "$BOLD$MAGENTA" "$NC"
  printf "  %s%s%s\n"                                                                 "$BOLD$MAGENTA" "$*" "$NC"
  printf "%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n"   "$BOLD$MAGENTA" "$NC"
}
phase() { printf "\n%s[%s]%s %s\n" "$BOLD$CYAN" "$1" "$NC" "$2"; }

# ---- core request function --------------------------------------------------
# Synchronous HTTP GET to a VIP. Captures headers (for X-Pod-Name / X-Node-Name),
# body (for pod=<n> / node=<n> fallback), status code, and latency. Logs
# per-request pod identity to $TMPDIR/pods.<svc> for aggregation in summary.
hit() {
  local svc="$1" label="${2:-$svc}" vip="${VIPS[$svc]}"
  local body_file="$TMPDIR/_body_$$_$RANDOM"
  local hdr_file="$TMPDIR/_hdr_$$_$RANDOM"
  local meta http_code time_s ms body pod_name node_name

  # Pre-create both output files so the subsequent reads never hit
  # "No such file or directory" if curl fails before any response bytes
  # land (connection refused, DNS error, etc.).
  : > "$body_file"
  : > "$hdr_file"

  # Don't merge stderr into stdout — curl writes error messages there that
  # would corrupt our "%{http_code}:%{time_total}" format. On any curl
  # failure, default to "000:0" so parsing stays clean downstream.
  meta=$(curl -s -o "$body_file" -D "$hdr_file" \
         -w "%{http_code}:%{time_total}" \
         --max-time "$CURL_TIMEOUT" "http://$vip/" 2>/dev/null) || meta="000:0"
  http_code="${meta%%:*}"
  time_s="${meta##*:}"
  ms=$(awk -v t="$time_s" 'BEGIN { printf "%.0f", t*1000 }')

  body=""
  if [[ -s "$body_file" ]]; then
    body=$(tr -d '\n\r' < "$body_file")
  fi

  # --- pod-identity detection -----------------------------------------------
  pod_name=""
  node_name=""
  if [[ -s "$hdr_file" ]]; then
    pod_name=$(awk 'BEGIN{IGNORECASE=1} /^X-Pod-Name:/  { sub(/^[^:]*:[[:space:]]*/,""); sub(/\r$/,""); print; exit }' "$hdr_file")
    node_name=$(awk 'BEGIN{IGNORECASE=1} /^X-Node-Name:/ { sub(/^[^:]*:[[:space:]]*/,""); sub(/\r$/,""); print; exit }' "$hdr_file")
  fi
  if [[ -z "$pod_name" ]] && [[ "$body" =~ pod=([A-Za-z0-9._-]+) ]]; then
    pod_name="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$node_name" ]] && [[ "$body" =~ node=([A-Za-z0-9._-]+) ]]; then
    node_name="${BASH_REMATCH[1]}"
  fi

  rm -f "$body_file" "$hdr_file"

  # --- record + display -----------------------------------------------------
  if [[ "$http_code" == "200" ]]; then
    echo "$ms" >> "$TMPDIR/lat.$svc"
    echo "OK"  >> "$TMPDIR/all.log"

    if [[ -n "$pod_name" ]]; then
      # Log full identity for the summary distribution table
      echo "$pod_name ${node_name:--}" >> "$TMPDIR/pods.$svc"
      # Inline: short form of pod name (the random suffix, e.g. 'x7f2k')
      local pod_short="${pod_name##*-}"
      printf "${GREEN}✓${NC} %-18s ${DIM}%4sms${NC}  ${CYAN}%-6s${NC}${DIM}@%-10s${NC} %s\n" \
             "$label" "$ms" "$pod_short" "${node_name:-?}" "$body"
    else
      printf "${GREEN}✓${NC} %-18s ${DIM}%4sms${NC}  %s\n" "$label" "$ms" "$body"
    fi
    return 0
  else
    echo "FAIL" >> "$TMPDIR/all.log"
    printf "${RED}✗${NC} %-18s ${DIM}%4sms${NC}  HTTP %s\n" "$label" "${ms:-?}" "${http_code:-timeout}"
    return 1
  fi
}

# Parallel version: run N workers concurrently against a service.
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

# ---- phases -----------------------------------------------------------------
phase_preflight() {
  phase preflight "Validating service endpoints (all VIPs must respond)"
  local ok=0
  for svc in param-server trainer inference data-loader; do
    printf "    "; hit "$svc" "$svc" && ok=$((ok+1))
  done
  if [[ $ok -lt 4 ]]; then
    printf "\n  ${RED}✗ Preflight failed — %d/4 services reachable. Aborting.${NC}\n" "$ok"
    exit 1
  fi
  printf "\n  ${GREEN}✓${NC} All 4 services healthy, proceeding with training.\n"
}

phase_load_data() {
  phase data-loader "Streaming training shards ($BATCHES_PER_EPOCH batches)"
  for i in $(seq 1 "$BATCHES_PER_EPOCH"); do
    printf "    "; hit data-loader "batch $i/$BATCHES_PER_EPOCH"
  done
}

phase_init_params() {
  phase param-server "Initializing shared parameters"
  printf "    "; hit param-server "init-weights"
}

phase_train_epoch() {
  local epoch="$1"
  phase "epoch $epoch/$EPOCHS" \
        "Training — $BATCHES_PER_EPOCH steps × $WORKERS workers (parallel)"
  for batch in $(seq 1 "$BATCHES_PER_EPOCH"); do
    printf "    ${DIM}step %d/%d:${NC}\n" "$batch" "$BATCHES_PER_EPOCH"
    parallel_hit trainer "$WORKERS" "w"
    if (( batch % PARAM_SYNC_EVERY == 0 )); then
      printf "      ${DIM}↳ gradient sync:${NC} "
      hit param-server "sync@step-$batch"
    fi
  done
  printf "    ${DIM}↳ end-of-epoch validation:${NC} "
  hit inference "epoch-$epoch-eval"
}

phase_deploy() {
  phase deploy "Promoting checkpoint to inference tier"
  printf "    "; hit inference "deploy-checkpoint"
}

phase_summary() {
  local end_ns elapsed_s total fails ok_count success_rate rps
  end_ns=$(date +%s%N)
  elapsed_s=$(awk -v s="$START_NS" -v e="$end_ns" 'BEGIN { printf "%.1f", (e-s)/1e9 }')
  total=$(wc -l < "$TMPDIR/all.log" 2>/dev/null | tr -d ' '); total=${total:-0}
  fails=$(grep -c '^FAIL' "$TMPDIR/all.log" 2>/dev/null | tr -d ' '); fails=${fails:-0}
  ok_count=$((total - fails))
  if [[ $total -gt 0 ]]; then
    success_rate=$(awk -v t="$total" -v o="$ok_count" 'BEGIN { printf "%.1f", o*100/t }')
    rps=$(awk -v t="$total" -v s="$elapsed_s" 'BEGIN { if (s>0) printf "%.1f", t/s; else printf "0.0" }')
  else
    success_rate="0.0"; rps="0.0"
  fi

  banner "Training Job Summary  ($JOB_ID)"
  printf "  ${BOLD}Total requests:${NC}       %d\n"              "$total"
  if [[ $fails -eq 0 ]]; then
    printf "  ${BOLD}Successful:${NC}           ${GREEN}%d (%s%%)${NC}\n"  "$ok_count" "$success_rate"
    printf "  ${BOLD}Failed:${NC}               ${GREEN}0${NC}\n"
  else
    printf "  ${BOLD}Successful:${NC}           %d (%s%%)\n"               "$ok_count" "$success_rate"
    printf "  ${BOLD}Failed:${NC}               ${RED}%d${NC}\n"           "$fails"
  fi
  printf "  ${BOLD}Wall time:${NC}            %ss\n"                       "$elapsed_s"
  printf "  ${BOLD}Throughput:${NC}           %s req/s\n"                  "$rps"

  # ---- per-service latency -------------------------------------------------
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

  # ---- pod landing distribution --------------------------------------------
  local any_pod_info=false svc
  for svc in param-server trainer inference data-loader; do
    [[ -s "$TMPDIR/pods.$svc" ]] && { any_pod_info=true; break; }
  done

  printf "\n  ${BOLD}Pod landing distribution (where each request actually landed):${NC}\n"
  if $any_pod_info; then
    for svc in param-server trainer inference data-loader; do
      if [[ -s "$TMPDIR/pods.$svc" ]]; then
        local total_svc uniq_pods
        total_svc=$(wc -l < "$TMPDIR/pods.$svc" | tr -d ' ')
        uniq_pods=$(awk '{print $1}' "$TMPDIR/pods.$svc" | sort -u | wc -l | tr -d ' ')
        printf "\n    ${BOLD}%-14s${NC} ${DIM}%d requests across %d pod(s)${NC}\n" \
               "$svc" "$total_svc" "$uniq_pods"
        sort "$TMPDIR/pods.$svc" | uniq -c | sort -rn | \
          while read -r count pod node; do
            local pct bar
            pct=$(awk -v c="$count" -v t="$total_svc" 'BEGIN { printf "%.0f", c*100/t }')
            # 20-char bar at 5% per block
            bar=""
            if [[ $pct -gt 0 ]]; then
              bar=$(printf '█%.0s' $(seq 1 $((pct/5 + 1))))
            fi
            printf "      %4d  %3s%%  ${GREEN}%-21s${NC}  ${CYAN}%-38s${NC}  ${DIM}on %s${NC}\n" \
                   "$count" "$pct" "$bar" "$pod" "$node"
          done
      fi
    done
  else
    printf "    ${DIM}(not available — backends don't report pod identity)${NC}\n\n"
    printf "    ${DIM}To enable per-request pod landing, deploy identity-aware services:${NC}\n"
    printf "    ${DIM}  on master:  ./deploy_identity_services.sh${NC}\n"
    printf "    ${DIM}That adds X-Pod-Name / X-Node-Name response headers to every reply.${NC}\n"
  fi

  # ---- fabric path ---------------------------------------------------------
  local leaf_edge
  leaf_edge=$(ip route get 192.168.100.0 2>/dev/null | awk '/via/ { for(i=1;i<=NF;i++) if ($i=="via") print $(i+1) }')
  printf "\n  ${BOLD}Fabric path exercised:${NC}\n"
  printf "    frontend  ${DIM}(%s)${NC}\n" "$(ip -4 addr show ens4 2>/dev/null | awk '/inet /{print $2; exit}')"
  printf "      ${DIM}│ ens4 static route 192.168.0.0/16${NC}\n"
  printf "    leaf SVI  ${DIM}(%s, VRF tenant-1)${NC}\n" "${leaf_edge:-unknown}"
  printf "      ${DIM}│ VRF tenant-1 FIB lookup → rack-local host eBGP path${NC}\n"
  printf "    K8s host  ${DIM}(receives on ens4, VIP on lo)${NC}\n"
  printf "      ${DIM}│ Cilium kubeProxyReplacement BPF (LB decision)${NC}\n"
  printf "    backend pod  ${DIM}(distribution shown above)${NC}\n"

  echo
  if [[ $fails -eq 0 ]]; then
    printf "  ${BOLD}${GREEN}✓ Training job completed successfully${NC}\n"
    printf "  ${DIM}$ok_count requests × ${elapsed_s}s wall → $rps req/s sustained${NC}\n"
    return 0
  else
    printf "  ${BOLD}${RED}✗ Training job completed with $fails failures${NC}\n"
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
