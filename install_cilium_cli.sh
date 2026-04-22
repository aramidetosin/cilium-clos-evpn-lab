#!/usr/bin/env bash
# Install the official Cilium CLI on master.
# Makes `cilium bgp peers`, `cilium status`, `cilium bgp routes` work directly,
# no more `kubectl exec ds/cilium -c cilium-agent -- cilium-dbg ...` mouthful.
#
# Run once on master.

set -euo pipefail

BLUE='\033[1;34m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}  OK:${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  WARN:${NC} %s\n" "$*"; }

if command -v cilium >/dev/null 2>&1; then
  warn "cilium CLI already installed: $(cilium version --client 2>/dev/null | head -1)"
  warn "Re-installing anyway to get the latest stable version..."
fi

log "Detecting architecture"
CLI_ARCH=amd64
case "$(uname -m)" in
  aarch64|arm64) CLI_ARCH=arm64 ;;
  x86_64)        CLI_ARCH=amd64 ;;
  *) echo "Unsupported arch: $(uname -m)"; exit 1 ;;
esac
ok "arch = $CLI_ARCH"

log "Resolving latest stable cilium-cli release"
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
ok "version = $CILIUM_CLI_VERSION"

cd /tmp
log "Downloading cilium-linux-${CLI_ARCH}.tar.gz + checksum"
curl -sfL --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

log "Verifying checksum"
sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"
ok "checksum matches"

log "Installing to /usr/local/bin"
sudo tar xzvf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
rm -f "cilium-linux-${CLI_ARCH}.tar.gz" "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

log "Verifying install"
cilium version --client
echo
ok "Done. Try these now:"
echo "  cilium status"
echo "  cilium bgp peers"
echo "  cilium bgp routes available ipv4 unicast"
echo "  cilium bgp routes advertised ipv4 unicast"
