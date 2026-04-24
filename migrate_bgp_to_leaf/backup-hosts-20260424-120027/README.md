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
