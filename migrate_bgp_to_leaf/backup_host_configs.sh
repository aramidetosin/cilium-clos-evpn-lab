#!/usr/bin/env bash
# =============================================================================
# backup_host_configs.sh
# -----------------------------------------------------------------------------
# Companion to backup_switch_configs.sh. Captures the host-side half of the
# design — everything needed to rebuild the FRR + vip-sync stack on a new node.
#
# Per-host layout (same shape as the switch backup for consistency):
#
#   configs/                    restore-ready
#     frr.conf                  /etc/frr/frr.conf
#     frr-daemons               /etc/frr/daemons
#     frr-vtysh.conf            /etc/frr/vtysh.conf (if present)
#     vip-sync.service          /etc/systemd/system/vip-sync.service
#     vip-sync.sh               /usr/local/bin/vip-sync.sh
#     netplan/*.yaml            /etc/netplan/*.yaml
#     hosts                     /etc/hosts
#   state/                      diagnostic snapshots
#     frr-running-config.txt    vtysh 'show running-config'
#     frr-bgp-summary.txt
#     frr-bgp-ipv4.txt
#     frr-ip-route.txt
#     frr-bfd-peers.txt
#     kernel-addr.txt           ip -4 addr show
#     kernel-routes.txt         ip -4 route show
#     kernel-routes-bgp.txt     ip -4 route show proto bgp
#     systemctl-frr.txt         systemctl status frr
#     systemctl-vip-sync.txt    systemctl status vip-sync
#     journal-frr.log           journalctl -u frr --no-pager -n 1000
#     journal-vip-sync.log      journalctl -u vip-sync --no-pager -n 1000
#
# Plus cluster-wide K8s manifests (captured once, from master):
#   k8s/
#     vip-sync-sa.yaml
#     vip-sync-clusterrole.yaml
#     vip-sync-clusterrolebinding.yaml
#     vip-sync-secret.yaml        ⚠ SENSITIVE — contains bearer token
#     loadbalancer-services.yaml
#     cilium-bgp-crs.yaml         (empty but documents absence)
#
# Usage:
#   ./backup_host_configs.sh                      # all hosts
#   ./backup_host_configs.sh master worker-1      # subset
#   NO_SECRETS=1 ./backup_host_configs.sh         # skip vip-sync-secret
# =============================================================================

set -uo pipefail

readonly SSH_USER="${SSH_USER:-user}"
readonly SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes"
readonly NO_SECRETS="${NO_SECRETS:-0}"
readonly JOURNAL_LINES="${JOURNAL_LINES:-1000}"

# name:ip:is_master
readonly NODES=(
  "master:10.1.1.10:true"
  "worker-1:10.1.2.10:false"
  "worker-2:10.1.3.10:false"
  "worker-3:10.1.4.10:false"
)

readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)
readonly BACKUP_DIR="$(pwd)/backup-hosts-${TIMESTAMP}"

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

# ---- one-shot host capture --------------------------------------------------
# Strategy: one SSH per host. On the remote side we gather files under /tmp,
# run commands into the same tree, then stream the whole thing back as a
# gzipped tar. Single round-trip per host, no rate-limit concerns, clean
# extraction locally.
#
# The remote script runs with the user's NOPASSWD sudo for reading /etc/
# config files (frr.conf is 640 root:frr — readable only via sudo unless
# the user is in the frr group).
backup_host() {
  local name="$1" ip="$2"
  local outdir="$BACKUP_DIR/$name"
  mkdir -p "$outdir"

  section "$name ($ip)"

  # Build the remote script. We use a quoted heredoc to prevent local
  # variable expansion; JOURNAL_LINES is injected via command-line env.
  local remote_script
  remote_script=$(cat <<'REMOTE'
set -uo pipefail
umask 077   # locked-down temp dir

TMPDIR=$(mktemp -d -t hostbackup.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
cd "$TMPDIR"
mkdir -p configs configs/netplan state

# ---- helper: copy a file if it exists, or drop a placeholder ---------------
pull() {
  local src="$1" dst="$2"
  if sudo test -f "$src"; then
    sudo cat "$src" > "$dst" 2>/dev/null
  else
    echo "# MISSING: $src was not present at $(date -Iseconds)" > "$dst"
  fi
}

# ---- helper: run a command, capture stdout+stderr --------------------------
run() {
  local cmd="$1" dst="$2"
  { echo "# $ $cmd"; echo "# $(date -Iseconds)"; echo; eval "$cmd"; } > "$dst" 2>&1 || true
}

# ---- config files ----------------------------------------------------------
pull /etc/frr/frr.conf                         configs/frr.conf
pull /etc/frr/daemons                          configs/frr-daemons
pull /etc/frr/vtysh.conf                       configs/frr-vtysh.conf
pull /etc/systemd/system/vip-sync.service      configs/vip-sync.service
pull /usr/local/bin/vip-sync.sh                configs/vip-sync.sh
pull /etc/hosts                                configs/hosts

# Netplan glob — preserve individual file names
for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
  [ -f "$f" ] || continue
  sudo cat "$f" > "configs/netplan/$(basename "$f")"
done

# ---- operational state -----------------------------------------------------
run "sudo vtysh -c 'show running-config'"          state/frr-running-config.txt
run "sudo vtysh -c 'show bgp summary'"             state/frr-bgp-summary.txt
run "sudo vtysh -c 'show bgp ipv4 unicast'"        state/frr-bgp-ipv4.txt
run "sudo vtysh -c 'show ip route'"                state/frr-ip-route.txt
run "sudo vtysh -c 'show bfd peers'"               state/frr-bfd-peers.txt

run "ip -4 addr show"                              state/kernel-addr.txt
run "ip -4 route show"                             state/kernel-routes.txt
run "ip -4 route show proto bgp"                   state/kernel-routes-bgp.txt

run "systemctl status frr --no-pager --lines=0"    state/systemctl-frr.txt
run "systemctl status vip-sync --no-pager --lines=0" state/systemctl-vip-sync.txt

# Journals — only lines since boot, clamped to JOURNAL_LINES_REPLACE
run "sudo journalctl -u frr --no-pager -n JOURNAL_LINES_REPLACE"      state/journal-frr.log
run "sudo journalctl -u vip-sync --no-pager -n JOURNAL_LINES_REPLACE" state/journal-vip-sync.log

# Hand ownership back to the invoking user so the tar stream is clean
sudo chown -R "$USER:$USER" . 2>/dev/null || true

# Stream the lot back as a gzipped tarball on stdout
tar czf - .
REMOTE
)

  # Inject JOURNAL_LINES into the remote script
  remote_script="${remote_script//JOURNAL_LINES_REPLACE/$JOURNAL_LINES}"

  # Execute and extract
  local rc
  ssh $SSH_OPTS "$SSH_USER@$ip" "bash -s" <<<"$remote_script" \
    | tar xzf - -C "$outdir" 2>/dev/null
  rc=${PIPESTATUS[0]}

  if [[ $rc -ne 0 ]]; then
    err "$name: SSH/remote script failed (rc=$rc)"
    return 1
  fi

  local n_files
  n_files=$(find "$outdir" -type f | wc -l)
  ok "$name: $n_files files captured"
}

# ---- K8s manifests (master only) --------------------------------------------
backup_k8s_manifests() {
  local name="$1" ip="$2"
  local outdir="$BACKUP_DIR/$name/k8s"
  mkdir -p "$outdir"

  section "K8s manifests (via kubectl on $name)"

  # All of these are run via ssh to the master so they use its kubeconfig;
  # this avoids assuming kubectl is locally installed where backup runs.
  local cmds=(
    "get sa vip-sync -n kube-system -o yaml:vip-sync-sa.yaml"
    "get clusterrole vip-sync-reader -o yaml:vip-sync-clusterrole.yaml"
    "get clusterrolebinding vip-sync-binding -o yaml:vip-sync-clusterrolebinding.yaml"
    "get svc -A --field-selector spec.type=LoadBalancer -o yaml:loadbalancer-services.yaml"
    "get ciliumbgpclusterconfig,ciliumbgppeerconfig,ciliumbgpadvertisement -o yaml --ignore-not-found:cilium-bgp-crs.yaml"
  )
  # Secret contains the bearer token — sensitive. Gated behind NO_SECRETS.
  if [[ "$NO_SECRETS" != "1" ]]; then
    cmds+=("get secret vip-sync-token -n kube-system -o yaml:vip-sync-secret.yaml")
  else
    info "  skipping vip-sync-secret (NO_SECRETS=1)"
  fi

  local entry kubectl_args dst raw
  for entry in "${cmds[@]}"; do
    kubectl_args="${entry%%:*}"
    dst="${entry#*:}"
    raw=$(ssh $SSH_OPTS "$SSH_USER@$ip" "kubectl $kubectl_args" 2>&1 || true)
    if [[ -z "$raw" ]]; then
      echo "# EMPTY (resource not found or kubectl error) — $(date -Iseconds)" > "$outdir/$dst"
      warn "  $dst: empty (resource may not exist)"
    else
      {
        echo "# ---------------------------------------------------------------"
        echo "# Command:  kubectl $kubectl_args"
        echo "# Captured: $(date -Iseconds)"
        [[ "$dst" == "vip-sync-secret.yaml" ]] && echo "# ⚠ SENSITIVE: contains bearer token — do NOT commit to public repos"
        echo "# ---------------------------------------------------------------"
        echo "$raw"
      } > "$outdir/$dst"
    fi
  done
  ok "$name: K8s manifests captured in $name/k8s/"
}

# ---- manifest ---------------------------------------------------------------
write_manifest() {
  local m="$BACKUP_DIR/MANIFEST.txt"
  {
    echo "# Host configuration backup"
    echo "# Generated: $(date -Iseconds)"
    echo "# Hostname:  $(hostname)"
    echo "# Script:    $0"
    echo "# Options:   NO_SECRETS=$NO_SECRETS JOURNAL_LINES=$JOURNAL_LINES"
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
# Host Configuration Backup

Snapshot of the host-side half of the VXLAN EVPN + FRR + vip-sync design.
Pairs with `backup-switches-*/` to form a complete disaster-recovery image.

## Layout

```
<host>/
  configs/
    frr.conf                  /etc/frr/frr.conf
    frr-daemons               /etc/frr/daemons
    frr-vtysh.conf            /etc/frr/vtysh.conf (if present)
    vip-sync.service          /etc/systemd/system/vip-sync.service
    vip-sync.sh               /usr/local/bin/vip-sync.sh
    netplan/*.yaml            /etc/netplan/*.yaml
    hosts                     /etc/hosts
  state/
    frr-running-config.txt    vtysh active configuration
    frr-bgp-summary.txt       BGP peer state
    frr-bgp-ipv4.txt          FRR BGP RIB
    frr-ip-route.txt          FRR view of the routing table
    frr-bfd-peers.txt         BFD peer state (down in this lab — virtual NX-OS)
    kernel-addr.txt           ip -4 addr show (includes lo VIPs)
    kernel-routes.txt         ip -4 route show
    kernel-routes-bgp.txt     proto bgp routes only — cross-checks FRR
    systemctl-frr.txt         unit status at backup time
    systemctl-vip-sync.txt    unit status at backup time
    journal-frr.log           last N lines of frr systemd journal
    journal-vip-sync.log      last N lines of vip-sync systemd journal

master/k8s/                   (only captured from the master node)
  vip-sync-sa.yaml                 ServiceAccount
  vip-sync-clusterrole.yaml        ClusterRole (list/watch/get services)
  vip-sync-clusterrolebinding.yaml Binding that glues SA to ClusterRole
  vip-sync-secret.yaml             ⚠ Bearer token for the SA — SENSITIVE
  loadbalancer-services.yaml       All type=LoadBalancer services
  cilium-bgp-crs.yaml              Confirms absence (should be empty/NotFound)
```

## Sensitive content

**`master/k8s/vip-sync-secret.yaml` contains a base64-encoded bearer token
with cluster-wide read access to Services.** Treat it like a credential:

- Do not commit to a public repository.
- If committing to a private repo, consider `git-crypt` or `sops` encryption.
- Or regenerate the kubeconfig on restore and skip this file entirely —
  the SA + ClusterRole + Binding manifests above are sufficient to recreate it.

Re-run the backup with `NO_SECRETS=1 ./backup_host_configs.sh` to skip this
file entirely.

## Restoring a host from this backup

1. Install FRR on the target node (`apt install frr frr-pythontools`).
2. Drop configs in place:
   ```bash
   sudo install -m 0640 -o frr -g frr configs/frr.conf       /etc/frr/frr.conf
   sudo install -m 0644 -o frr -g frr configs/frr-daemons    /etc/frr/daemons
   sudo install -m 0644                configs/vip-sync.service \
                                                              /etc/systemd/system/
   sudo install -m 0755                configs/vip-sync.sh   /usr/local/bin/
   sudo cp configs/netplan/*.yaml                            /etc/netplan/
   sudo netplan apply
   sudo systemctl daemon-reload
   ```
3. Regenerate the vip-sync kubeconfig on the master from the backed-up
   secret manifest, scp it to the node, install at `/etc/vip-sync/kubeconfig`
   (mode 0600, owner root). See `master/k8s/vip-sync-sa.yaml` + the secret.
4. Start services:
   ```bash
   sudo systemctl enable --now frr vip-sync
   ```
5. Validate with `validate_frr_bgp.sh` from the top-level repo.

## Diffing against a previous snapshot

Most files start with a comment header noting the source command and capture
timestamp. For clean diffs strip the header:

```bash
diff -u \
  <(sed '/^# /d' backup-hosts-OLD/master/state/frr-bgp-summary.txt) \
  <(sed '/^# /d' backup-hosts-NEW/master/state/frr-bgp-summary.txt)
```

Config files under `configs/` don't have added headers and diff cleanly
as-is.

## What's deliberately NOT captured

- **Cilium configuration** — the CNI itself. Backed up via Helm values or
  whatever you used to install it. Not this script's scope.
- **Cluster state** (pods, deployments, etcd) — use `velero` or a proper
  K8s backup tool for that.
- **Container images** — infrastructure-as-code should rebuild these.
EOF
  ok "readme:   $r"
}

# ---- main -------------------------------------------------------------------
main() {
  banner "Host configuration backup — $TIMESTAMP"
  mkdir -p "$BACKUP_DIR"
  info "output: $BACKUP_DIR"
  [[ "$NO_SECRETS" == "1" ]] && info "NO_SECRETS=1 — vip-sync-secret.yaml will be skipped"

  local -a targets=()
  if [[ $# -gt 0 ]]; then
    for arg in "$@"; do
      for n in "${NODES[@]}"; do
        [[ "${n%%:*}" == "$arg" ]] && targets+=("$n")
      done
    done
    [[ ${#targets[@]} -eq 0 ]] && { err "no hosts matched: $*"; return 1; }
  else
    targets=("${NODES[@]}")
  fi

  local failed=0 master_name="" master_ip=""
  for n in "${targets[@]}"; do
    IFS=: read -r name ip is_master <<<"$n"
    backup_host "$name" "$ip" || failed=$((failed+1))
    [[ "$is_master" == "true" ]] && { master_name="$name"; master_ip="$ip"; }
  done

  # K8s manifests — capture once, from the first master we saw
  if [[ -n "$master_name" ]]; then
    backup_k8s_manifests "$master_name" "$master_ip" || failed=$((failed+1))
  else
    warn "no master in targets — skipping K8s manifest capture"
  fi

  banner "Finalize"
  write_readme
  write_manifest

  local tarball="${BACKUP_DIR}.tar.gz"
  tar czf "$tarball" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")"
  ok "tarball:  $tarball ($(du -h "$tarball" | cut -f1))"

  echo
  if [[ $failed -eq 0 ]]; then
    printf "  %sSUCCESS%s: %d/%d hosts captured\n" "$BOLD$GREEN" "$NC" \
           "${#targets[@]}" "${#targets[@]}"
  else
    printf "  %sPARTIAL%s: %d/%d hosts (%d failed)\n" "$BOLD$YELLOW" "$NC" \
           "$((${#targets[@]} - failed))" "${#targets[@]}" "$failed"
    return 1
  fi
}

main "$@"
