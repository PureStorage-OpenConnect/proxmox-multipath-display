#!/bin/bash
# Proxmox Multipath Display Plugin - GUI Installer
# Installs the GUI components:
#   1. Appends MultipathDisplay.js to pvemanagerlib.js
#   2. Patches Status.pm to include multipath data in API responses

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PVEMANAGERLIB="/usr/share/pve-manager/js/pvemanagerlib.js"
BACKUP_DIR="/var/lib/multipath-display-plugin"
BACKUP_FILE="$BACKUP_DIR/pvemanagerlib.js.original"
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

# Check if pvemanagerlib.js exists
if [ ! -f "$PVEMANAGERLIB" ]; then
    error "pvemanagerlib.js not found at $PVEMANAGERLIB"
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Check if already installed
if grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
    log "Multipath Display GUI is already installed."
    log "To reinstall, first run the uninstall script."
    exit 0
fi

# Backup original file
if [ ! -f "$BACKUP_FILE" ]; then
    log "Backing up original pvemanagerlib.js..."
    cp "$PVEMANAGERLIB" "$BACKUP_FILE"
fi

log "Installing Multipath Display GUI..."

# Append our ExtJS code with markers
log "  - Appending Multipath Display GUI to pvemanagerlib.js..."
{
    echo ""
    echo "$MARKER_START"
    cat "$SCRIPT_DIR/www/MultipathDisplay.js"
    echo ""
    echo "$MARKER_END"
} >> "$PVEMANAGERLIB"

if grep -q "$MARKER_START" "$PVEMANAGERLIB"; then
    log "  ✓ Multipath Display GUI appended successfully"
else
    error "Failed to append GUI code"
fi

# Apply Storage Status API patch
STORAGE_STATUS_PM="/usr/share/perl5/PVE/API2/Storage/Status.pm"
STORAGE_PATCH_MARKER="# MULTIPATH-DISPLAY-PATCHED"

if [ -f "$STORAGE_STATUS_PM" ]; then
    if grep -q "$STORAGE_PATCH_MARKER" "$STORAGE_STATUS_PM"; then
        log "  - Storage Status API already patched"
    else
        log "  - Patching Storage Status API..."

        # Backup original
        if [ ! -f "$BACKUP_DIR/Status.pm.original" ]; then
            cp "$STORAGE_STATUS_PM" "$BACKUP_DIR/Status.pm.original"
        fi

        # Apply the patch
        if patch --dry-run -p1 < "$SCRIPT_DIR/patches/storage-status-multipath.patch" -d / >/dev/null 2>&1; then
            patch -p1 < "$SCRIPT_DIR/patches/storage-status-multipath.patch" -d /
            log "  ✓ Storage Status API patched successfully"
        else
            log "  - Patch command failed, using sed insertion..."

            # Find the line number of "if !defined($data);" in the read_status method
            LINE_NUM=$(grep -n 'if !defined($data);' "$STORAGE_STATUS_PM" | tail -1 | cut -d: -f1)

            if [ -n "$LINE_NUM" ]; then
                # Create the code to insert - uses our MultipathStatusPlugin for everything
                cat > /tmp/multipath-insert.txt << 'INSERTCODE'

        # Multipath Display Plugin: Add multipath status
        eval {
            require PVE::Storage::Common::MultipathStatusPlugin;
            my $mpath_scfg = PVE::Storage::storage_config($cfg, $param->{storage});
            my $mpath_status = PVE::Storage::Common::MultipathStatusPlugin->get_multipath_status($param->{storage}, $mpath_scfg);
            $data->{multipathStatus} = $mpath_status if $mpath_status && $mpath_status->{active};
        };
INSERTCODE

                # Insert after the line with "if !defined($data);"
                sed -i "${LINE_NUM}r /tmp/multipath-insert.txt" "$STORAGE_STATUS_PM"

                # Add marker at top
                sed -i '1i# MULTIPATH-DISPLAY-PATCHED' "$STORAGE_STATUS_PM"

                rm -f /tmp/multipath-insert.txt

                if grep -q "multipathStatus" "$STORAGE_STATUS_PM"; then
                    log "  ✓ Storage Status API patched successfully (manual)"
                else
                    error "Failed to patch Status.pm - manual intervention required"
                fi
            else
                error "Could not find insertion point in Status.pm"
            fi
        fi
    fi
else
    warn "Storage Status.pm not found at $STORAGE_STATUS_PM"
fi

# Restart services
log "Restarting pvedaemon..."
systemctl restart pvedaemon

log "Restarting pveproxy..."
systemctl restart pveproxy

log ""
log "============================================"
log "Multipath Display GUI installation complete!"
log "============================================"
log ""
log "IMPORTANT: Clear your browser cache (Ctrl+Shift+R)"
log ""
log "Multipath status will now appear for:"
log "  - iSCSI Multipath storages (iscsimpath)"
log "  - NVMe-TCP storages (nvmetcp)"
log "  - LVM storages backed by multipath devices"
log ""
log "To uninstall: ./uninstall.sh"
log ""

