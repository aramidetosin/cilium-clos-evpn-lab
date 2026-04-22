#!/bin/bash
set -e
sed -i '/# k8s-fabric-lab/d' /etc/hosts
cat >> /etc/hosts <<HOSTS
10.1.1.10 master   # k8s-fabric-lab
10.1.2.10 worker-1   # k8s-fabric-lab
10.1.3.10 worker-2   # k8s-fabric-lab
10.1.4.10 worker-3   # k8s-fabric-lab
HOSTS
