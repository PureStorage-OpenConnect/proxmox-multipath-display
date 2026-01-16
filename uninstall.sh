#!/bin/bash
# Proxmox Multipath Display Plugin Uninstaller

set -e

PVEMANAGERLIB="/usr/share/pve-manager/js/pvemanagerlib.js"
BACKUP_DIR="/var/lib/multipath-display-plugin"
PLUGIN_DIR="/usr/share/perl5/PVE/Storage/Common"
API_DIR="/usr/share/perl5/PVE/API2"
MARKER_START="// ========== MULTIPATH-DISPLAY-PLUGIN-START =========="
MARKER_END="// ========== MULTIPATH-DISPLAY-PLUGIN-END =========="

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

log "Uninstalling Proxmox Multipath Display Plugin..."

# Remove GUI code from pvemanagerlib.js
if [ -f "$PVEMANAGERLIB" ]; then
    if grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
        log "Removing Multipath Display GUI from pvemanagerlib.js..."
        # Use a temporary file to avoid sed issues with special characters
        grep -v -A 10000 "$MARKER_START" "$PVEMANAGERLIB" > "$PVEMANAGERLIB.tmp1" || true
        grep -v -B 10000 "$MARKER_END" "$PVEMANAGERLIB" > "$PVEMANAGERLIB.tmp2" || true
        # Find the line number of markers and remove the section
        START_LINE=$(grep -n "$MARKER_START" "$PVEMANAGERLIB" | cut -d: -f1 | head -1)
        END_LINE=$(grep -n "$MARKER_END" "$PVEMANAGERLIB" | cut -d: -f1 | tail -1)
        if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
            sed -i "${START_LINE},${END_LINE}d" "$PVEMANAGERLIB"
            log "  ✓ GUI code removed"
        else
            warn "Could not find marker lines"
        fi
        rm -f "$PVEMANAGERLIB.tmp1" "$PVEMANAGERLIB.tmp2"
    else
        log "  - GUI code not found in pvemanagerlib.js"
    fi
fi

# Restore original Status.pm if backup exists
STORAGE_STATUS_PM="/usr/share/perl5/PVE/API2/Storage/Status.pm"
if [ -f "$BACKUP_DIR/Status.pm.original" ]; then
    log "Restoring original Storage Status.pm..."
    cp "$BACKUP_DIR/Status.pm.original" "$STORAGE_STATUS_PM"
    log "  ✓ Status.pm restored"
elif [ -f "$STORAGE_STATUS_PM" ]; then
    if grep -q "MULTIPATH-DISPLAY-PATCHED" "$STORAGE_STATUS_PM"; then
        warn "Status.pm is patched but no backup found"
        warn "You may need to reinstall pve-manager to restore the original"
    fi
fi

# Remove plugin files
if [ -f "$PLUGIN_DIR/MultipathStatusPlugin.pm" ]; then
    log "Removing MultipathStatusPlugin.pm..."
    rm -f "$PLUGIN_DIR/MultipathStatusPlugin.pm"
    log "  ✓ Removed"
fi

if [ -f "$API_DIR/MultipathStatus.pm" ]; then
    log "Removing MultipathStatus.pm API..."
    rm -f "$API_DIR/MultipathStatus.pm"
    log "  ✓ Removed"
fi

# Restart services
log "Restarting pvedaemon..."
systemctl restart pvedaemon

log "Restarting pveproxy..."
systemctl restart pveproxy

log ""
log "============================================"
log "Multipath Display Plugin uninstalled!"
log "============================================"
log ""
log "IMPORTANT: Clear your browser cache (Ctrl+Shift+R)"
log ""
log "Backup files are preserved in: $BACKUP_DIR"
log ""

