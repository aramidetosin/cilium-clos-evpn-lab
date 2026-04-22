# Run this FROM master to check host persistence on every node
for h in master 10.1.2.10 10.1.3.10 10.1.4.10; do
  echo ""
  echo "════════════════════════════════════════════════════"
  echo " Host persistence check: $h"
  echo "════════════════════════════════════════════════════"
  if [ "$h" = "master" ]; then
    CMD=bash
  else
    CMD="ssh -o StrictHostKeyChecking=no user@$h bash"
  fi
  $CMD <<'EOF'
  echo "--- kernel modules loaded at boot ---"
  cat /etc/modules-load.d/k8s.conf 2>/dev/null || echo "  MISSING"
  echo ""
  echo "--- sysctl ---"
  cat /etc/sysctl.d/99-k8s.conf 2>/dev/null || echo "  MISSING"
  echo ""
  echo "--- swap in fstab (should be commented) ---"
  grep -E 'swap' /etc/fstab || echo "  no swap entry"
  echo ""
  echo "--- services enabled ---"
  for svc in containerd kubelet; do
    printf "  %-12s enabled=%s active=%s\n" \
      "$svc" \
      "$(systemctl is-enabled $svc 2>/dev/null)" \
      "$(systemctl is-active $svc 2>/dev/null)"
  done
  echo ""
  echo "--- netplan files ---"
  ls /etc/netplan/
  echo ""
  echo "--- fabric IP present? ---"
  ip -br addr show ens4 2>/dev/null || echo "  ens4 MISSING"
EOF
done
