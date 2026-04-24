#!/usr/bin/env bash
# =============================================================================
# backup_switch_configs.sh
# -----------------------------------------------------------------------------
# Snapshot every leaf in the VXLAN EVPN fabric. Writes two kinds of artifacts
# per leaf:
#
#   configs/  — 'show running-config' split into per-topic files (full,
#               bgp, interface, bfd, nve, evpn, vrf, prefix-list, route-map).
#               These are restore-ready and diff cleanly across snapshots.
#
#   state/    — operational snapshots: BGP summary/RIB, EVPN RIB, route table,
#               NVE peers/VNI mappings, BFD details, MAC table, VRF list.
#               Useful for post-mortems and trend detection, not restoration.
#
# Spines are NOT captured: they're only reachable via the underlay, and this
# script runs from a K8s master whose only path into the fabric is its
# rack-local leaf SVI (inside VRF tenant-1). Run a spine-backup from a jump
# host that has underlay connectivity.
#
# Usage:
#   ./backup_switch_configs.sh                    # all leaves
#   ./backup_switch_configs.sh Leaf-1 Leaf-3      # subset
# =============================================================================

set -uo pipefail

readonly SW_USER="${SW_USER:-admin}"
readonly SW_PASS="${SW_PASS:-admin}"
readonly SSH_OPTS_NXOS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o PubkeyAuthentication=no -o PreferredAuthentications=password -o HostKeyAlgorithms=+ssh-rsa"

# name:svi
readonly LEAVES=(
  "Leaf-1:10.1.1.1"
  "Leaf-2:10.1.2.1"
  "Leaf-3:10.1.3.1"
  "Leaf-4:10.1.4.1"
)

readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly BACKUP_DIR="$(pwd)/backup-switches-${TIMESTAMP}"

# filename-stem : CLI command
# Order matters — indexes match nxos_batch_section N
readonly -a VIEWS=(
  # ---- config views (restorable) ------------------------------------------
  "configs/running-config:show running-config"
  "configs/running-config-bgp:show running-config bgp"
  "configs/running-config-interface:show running-config interface"
  "configs/running-config-bfd:show running-config bfd"
  "configs/running-config-nve:show running-config nv overlay"
  "configs/running-config-evpn:show running-config evpn"
  # Note: 'show running-config vrf' is rejected as a syntax error on NX-OS
  # 10.5(2) n9kv. VRF context is already in the full running-config above
  # (under 'vrf context tenant-1' blocks). Grep it out if you want a focused
  # view: awk '/^vrf context/,/^$/' running-config.cfg
  "configs/prefix-lists:show ip prefix-list"
  "configs/route-maps:show route-map"

  # ---- operational state (diagnostic) --------------------------------------
  "state/bgp-summary:show bgp ipv4 unicast summary vrf tenant-1"
  "state/bgp-rib-tenant1:show ip bgp vrf tenant-1"
  "state/evpn-rib:show bgp l2vpn evpn"
  "state/ip-route-tenant1:show ip route vrf tenant-1"
  "state/nve-peers:show nve peers"
  "state/nve-vni:show nve vni"
  "state/bfd-neighbors:show bfd neighbors vrf tenant-1 details"
  "state/mac-table:show mac address-table"
  "state/vrf:show vrf"
)

# ---- display ----------------------------------------------------------------
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

# ---- noise strippers --------------------------------------------------------
# Pre-command chatter (NTP warnings, stty complaints) is cruft. Actual config
# markers (!Command: / !Running configuration / !Time:) are kept — they're
# part of the NX-OS config-file format.
strip_noise() {
  awk '
    /^Warning: No NTP/             { next }
    /^Time source is NTP/          { next }
    /^stty:/                       { next }
    /^gl_set_term_size/            { next }
    /^[[:space:]]*$/ && prev_blank { next }
    { print; prev_blank = ($0 ~ /^[[:space:]]*$/) }
  '
}

# ---- batched SSH ------------------------------------------------------------
# Run all VIEWS commands in a single SSH session, separated by `show clock`
# markers. NX-OS throttles repeated same-source SSH auth (we've been bitten
# by this before — 4 consecutive connections hang), so batching is the only
# way to reliably pull many commands from one leaf.
LEAF_BATCH_RAW=""
nxos_batch_run() {
  local svi="$1"; shift
  local cmds=("$@")

  local input="terminal length 0"$'\n'
  for c in "${cmds[@]}"; do
    input+="show clock"$'\n'"$c"$'\n'
  done
  input+="exit"$'\n'

  LEAF_BATCH_RAW=$(timeout 120 sshpass -p "$SW_PASS" \
                   ssh -T $SSH_OPTS_NXOS "$SW_USER@$svi" <<<"$input" 2>&1 || true)
}

nxos_batch_section() {
  local idx="$1"
  echo "$LEAF_BATCH_RAW" | awk -v n="$idx" '
    /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+[[:space:]]+[A-Z]+/ { c++; next }
    c == n+1 { print }
  '
}

# ---- backup a single leaf ---------------------------------------------------
backup_leaf() {
  local lname="$1" svi="$2"
  local outdir="$BACKUP_DIR/$lname"
  mkdir -p "$outdir/configs" "$outdir/state"

  section "$lname ($svi)"
  info "  fetching ${#VIEWS[@]} views in a single SSH session..."

  # Extract the commands from VIEWS[] into a positional array
  local -a cmds=()
  for v in "${VIEWS[@]}"; do
    cmds+=("${v#*:}")
  done

  nxos_batch_run "$svi" "${cmds[@]}"
  if [[ -z "$LEAF_BATCH_RAW" ]]; then
    err "$lname: SSH returned no output (timeout? unreachable?)"
    return 1
  fi

  # Split and persist each section
  local idx=0 stem cmd outfile content ext empty=0
  for v in "${VIEWS[@]}"; do
    stem="${v%%:*}"
    cmd="${v#*:}"
    if [[ "$stem" == configs/* ]]; then ext="cfg"; else ext="txt"; fi
    outfile="$outdir/${stem}.${ext}"
    content=$(nxos_batch_section "$idx" | strip_noise)

    # Prepend a small banner identifying the source command — helpful when
    # someone opens a random file from the archive in six months
    {
      echo "! ====================================================="
      echo "! Host:     $lname ($svi)"
      echo "! Command:  $cmd"
      echo "! Captured: $(date -Iseconds)"
      echo "! ====================================================="
      echo
      echo "$content"
    } > "$outfile"

    # Size sanity
    if [[ -z "$(echo "$content" | tr -d '[:space:]')" ]]; then
      warn "  [$idx] $stem: EMPTY (command may not be supported on this NX-OS build)"
      empty=$((empty+1))
    fi

    idx=$((idx+1))
  done

  if [[ $empty -gt 0 ]]; then
    warn "$lname: ${#VIEWS[@]} files written, but $empty are empty — review above"
  else
    ok "$lname: ${#VIEWS[@]} files written to $lname/"
  fi
}

# ---- manifest ---------------------------------------------------------------
write_manifest() {
  local m="$BACKUP_DIR/MANIFEST.txt"
  {
    echo "# Switch configuration backup"
    echo "# Generated: $(date -Iseconds)"
    echo "# Host:      $(hostname)"
    echo "# Script:    $0"
    echo
    echo "# Files (size in bytes, relative path)"
    ( cd "$BACKUP_DIR" && find . -type f ! -name MANIFEST.txt ! -name README.md -print \
        | sort \
        | xargs -I{} sh -c 'printf "%8d  %s\n" "$(wc -c < "{}")" "{}"' )
  } > "$m"
  ok "manifest: $m"
}

# ---- README -----------------------------------------------------------------
write_readme() {
  local r="$BACKUP_DIR/README.md"
  cat > "$r" <<'EOF'
# Switch Configuration Backup

Snapshot of the VXLAN EVPN fabric leaves (Leaf-1..Leaf-4), taken after the
Cilium→FRR productionization. Captured by `backup_switch_configs.sh`.

## Layout

```
Leaf-N/
  configs/                    # restore-ready NX-OS configuration
    running-config.cfg        # full config — this is the authoritative file
    running-config-bgp.cfg    # `show running-config bgp` alone (diff-friendly)
    running-config-interface.cfg
    running-config-bfd.cfg
    running-config-nve.cfg    # VXLAN overlay config
    running-config-evpn.cfg
    running-config-vrf.cfg
    prefix-lists.cfg          # `show ip prefix-list`
    route-maps.cfg            # `show route-map`
  state/                      # operational state (diagnostic, not for restore)
    bgp-summary.txt           # VRF tenant-1 IPv4 summary
    bgp-rib-tenant1.txt       # VRF IPv4 BGP table
    evpn-rib.txt              # L2VPN EVPN table (all RDs)
    ip-route-tenant1.txt      # VRF URIB
    nve-peers.txt             # VXLAN tunnel peers
    nve-vni.txt               # VNI → VLAN/VRF mappings
    bfd-neighbors.txt         # BFD session details (VRF tenant-1)
    mac-table.txt             # unicast MAC table
    vrf.txt                   # VRF list
```

## What was intentionally NOT captured

**Spines.** The two spine switches are only reachable via underlay IPs
(10.0.0.1, 10.0.0.2). This script runs from a host inside VRF tenant-1 via
the rack-local leaf SVI, which cannot route to the underlay. Back spines up
from a jump box that has underlay reachability.

**Host-side configs.** FRR, vip-sync systemd units, and netplan live on the
Kubernetes nodes, not the switches. Back those up separately — they're the
other half of the design and required for a full disaster-recovery story.

## Restoring a leaf from this backup

1. Console into the leaf (out-of-band — don't rely on the SVI you're about
   to overwrite).
2. `copy <external:>running-config.cfg bootflash:`
3. `copy bootflash:running-config.cfg running-config`
4. `copy running-config startup-config`

**Warning:** `copy … running-config` merges rather than replacing. For a
true restore, use `configure replace bootflash:running-config.cfg` if your
NX-OS image supports it, or be prepared to manually reconcile leftover
state with `no` commands.

## Diffing against a previous snapshot

Each config file starts with a 5-line banner (`! Host: / Command: / Captured:`).
For stable diffs, strip that banner and any `!Time: <date>` lines generated by
NX-OS itself:

```bash
diff -u \
  <(sed '/^! /d; /^!Time:/d' backup-switches-OLD/Leaf-1/configs/running-config.cfg) \
  <(sed '/^! /d; /^!Time:/d' backup-switches-NEW/Leaf-1/configs/running-config.cfg)
```

For committing to git, the per-topic split files (`running-config-bgp.cfg`
etc.) produce much cleaner diffs than the monolithic `running-config.cfg`.
EOF
  ok "readme:   $r"
}

# ---- main -------------------------------------------------------------------
main() {
  command -v sshpass >/dev/null || { err "sshpass not found — install it and retry"; return 1; }

  banner "Switch configuration backup — $TIMESTAMP"
  mkdir -p "$BACKUP_DIR"
  info "output: $BACKUP_DIR"

  # Filter by CLI args if provided
  local -a targets=()
  if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
      for lf in "${LEAVES[@]}"; do
        [[ "${lf%%:*}" == "$arg" ]] && targets+=("$lf")
      done
    done
    [[ ${#targets[@]} -eq 0 ]] && { err "no leaves matched: $*"; return 1; }
  else
    targets=("${LEAVES[@]}")
  fi

  local failed=0
  for lf in "${targets[@]}"; do
    IFS=: read -r name svi <<<"$lf"
    backup_leaf "$name" "$svi" || failed=$((failed+1))
  done

  banner "Finalize"
  write_readme
  write_manifest

  # Convenience: also tar it up for archival
  local tarball="${BACKUP_DIR}.tar.gz"
  tar czf "$tarball" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
  ok "tarball:  $tarball ($(du -h "$tarball" | cut -f1))"

  echo
  if [[ $failed -eq 0 ]]; then
    printf "  %sSUCCESS%s: %d/%d leaves captured\n" "$BOLD$GREEN" "$NC" \
           "${#targets[@]}" "${#targets[@]}"
  else
    printf "  %sPARTIAL%s: %d/%d leaves captured (%d failed)\n" "$BOLD$YELLOW" "$NC" \
           "$((${#targets[@]} - failed))" "${#targets[@]}" "$failed"
    return 1
  fi
}

main "$@"
