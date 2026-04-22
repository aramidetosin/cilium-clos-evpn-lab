#!/usr/bin/env bash
# Quick persistence check - run before and after reboot to compare.

echo "=== Host config (should be identical before/after reboot) ==="
echo ""
echo "--- netplan ---"
ls -la /etc/netplan/
echo ""
echo "--- sysctl k8s ---"
cat /etc/sysctl.d/99-k8s.conf
echo ""
echo "--- modules-load ---"
cat /etc/modules-load.d/k8s.conf
echo ""
echo "--- fstab swap ---"
grep swap /etc/fstab
echo ""
echo "--- kubernetes manifests (static pods) ---"
sudo ls -la /etc/kubernetes/manifests/
echo ""
echo "--- enabled services ---"
for svc in containerd kubelet; do
  printf "  %-12s enabled=%s active=%s\n" \
    "$svc" \
    "$(systemctl is-enabled $svc)" \
    "$(systemctl is-active $svc)"
done
echo ""
echo "=== Cluster state (should match after ~90s post-reboot) ==="
kubectl get nodes -o wide
echo ""
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
echo ""
cilium bgp peers
echo ""
kubectl -n ai-training get svc -o wide
echo ""
echo "=== Gotcha check ==="
echo "--- Stray KUBECONFIG exports? ---"
grep -r 'KUBECONFIG' /etc/environment /etc/profile /etc/profile.d/ \
  /etc/bash.bashrc ~/.bashrc ~/.profile ~/.bash_profile 2>/dev/null || echo "  clean"
