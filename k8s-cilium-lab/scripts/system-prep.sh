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
