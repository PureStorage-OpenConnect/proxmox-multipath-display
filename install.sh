#!/bin/bash
# Proxmox Multipath Display Plugin Installer
# Transport-agnostic multipath status display for Proxmox VE
#
# Supports:
#   - iSCSI Multipath (iscsimpath) storage
#   - NVMe-TCP (nvmetcp) storage
#   - LVM backed by multipath devices

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="/usr/share/perl5/PVE/Storage/Common"
API_DIR="/usr/share/perl5/PVE/API2"
BACKUP_DIR="/var/lib/multipath-display-plugin"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" >&2
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error "Please run as root"
fi

# Check if this is a Proxmox system
if [ ! -f /etc/pve/pve-root-ca.pem ]; then
    error "This does not appear to be a Proxmox VE system"
fi

log "Installing Proxmox Multipath Display Plugin..."

# Create directories
log "Creating directories..."
mkdir -p "$PLUGIN_DIR"
mkdir -p "$API_DIR"
mkdir -p "$BACKUP_DIR"

# Install core plugin
log "Installing MultipathStatusPlugin.pm..."
cp "$SCRIPT_DIR/src/PVE/Storage/Common/MultipathStatusPlugin.pm" "$PLUGIN_DIR/"
chmod 644 "$PLUGIN_DIR/MultipathStatusPlugin.pm"

# Install API module
log "Installing MultipathStatus.pm API..."
cp "$SCRIPT_DIR/src/PVE/API2/MultipathStatus.pm" "$API_DIR/"
chmod 644 "$API_DIR/MultipathStatus.pm"

# Verify installation
if perl -e 'use PVE::Storage::Common::MultipathStatusPlugin;' 2>/dev/null; then
    log "  ✓ Plugin loaded successfully"
else
    warn "Plugin may not load correctly - check for missing dependencies"
fi

log "Core plugin installation complete!"
log ""

# Ask if user wants to install GUI
read -p "Do you want to install the GUI components? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Installing GUI components..."
    if [ -f "$SCRIPT_DIR/install-gui.sh" ]; then
        bash "$SCRIPT_DIR/install-gui.sh"
    else
        error "install-gui.sh not found in $SCRIPT_DIR"
    fi
else
    log "Skipping GUI installation."
    log "To install GUI components later, run: ./install-gui.sh"
    log ""
fi

