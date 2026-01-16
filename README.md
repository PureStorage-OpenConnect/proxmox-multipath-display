# Proxmox Multipath Display Plugin

A transport-agnostic multipath status display plugin for Proxmox VE. Shows real-time path status for multipath storage directly in the Proxmox web UI.

## Features

- **iSCSI Multipath** (iscsimpath): Shows dm-multipath status with portal, target, and interface info
- **NVMe-TCP** (nvmetcp): Shows native NVMe multipath status with controller and namespace info
- **LVM on Multipath**: Detects LVM volumes backed by multipath devices

## Screenshots

The plugin adds a "Multipath Status" panel to the storage Summary page showing:
- Path count summary (e.g., "4/4 paths active")
- Per-device path details with state indicators
- Transport-specific information (portals, targets, controllers)

## Requirements

- Proxmox VE 9.x
- `multipath-tools` package (for iSCSI multipath)
- `nvme-cli` package (for NVMe-TCP)

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/proxmox-multipath-display.git
cd proxmox-multipath-display

# Run the installer as root
sudo ./install.sh
```

The installer will:
1. Install the core Perl plugin (`MultipathStatusPlugin.pm`)
2. Install the API module (`MultipathStatus.pm`)
3. Optionally install GUI components (patches `pvemanagerlib.js` and `Status.pm`)

After installation, clear your browser cache (Ctrl+Shift+R) to see the changes.

## Uninstallation

```bash
sudo ./uninstall.sh
```

This restores all original files from backups stored in `/var/lib/multipath-display-plugin/`.

## How It Works

### Backend (Perl)

The `MultipathStatusPlugin.pm` module provides:
- `get_multipath_status($storeid, $scfg)`: Main entry point that detects storage type and returns path status
- `get_dm_multipath_status()`: Parses `multipathd show maps json` output for dm-multipath devices
- `get_nvme_multipath_status($scfg)`: Queries NVMe subsystems via `/sys/class/nvme-subsystem/`

The `Status.pm` patch injects multipath data into the storage status API response.

### Frontend (JavaScript)

The `MultipathDisplay.js` module:
- Hooks into `PVE.storage.Summary` to add a multipath status panel
- Fetches status from the standard `/nodes/{node}/storage/{storage}/status` API
- Renders path information with color-coded status indicators
- **Validated only on Proxmox VE 9.1.4**

## Supported Storage Types

| Storage Type | Detection Method | Path Info |
|--------------|------------------|-----------|
| `iscsimpath` | dm-multipath via multipathd | Portal, Target, Host Interface |
| `nvmetcp` | Native NVMe via sysfs | Controller, Portal, Host Interface |
| `lvm` | Checks if PV is on multipath | Same as underlying multipath device |

## API Response

The plugin adds a `multipathStatus` object to the storage status API:

```json
{
  "multipathStatus": {
    "active": 1,
    "total_paths": 4,
    "active_paths": 4,
    "failed_paths": 0,
    "devices": [
      {
        "name": "3624a937...",
        "vendor": "PURE",
        "product": "FlashArray",
        "size": "5.0T",
        "paths": [
          {
            "device": "sdb",
            "dmState": "running",
            "portal": "10.21.136.20:3260",
            "target": "iqn.2010-06.com.purestorage:...",
            "hostIface": "ens1f0np0.2136",
            "transport": "iscsi"
          }
        ]
      }
    ]
  }
}
```

## Troubleshooting

### Plugin not loading
```bash
perl -e 'use PVE::Storage::Common::MultipathStatusPlugin;'
```

### Check multipath status manually
```bash
# For dm-multipath
multipathd show maps json

# For NVMe
ls /sys/class/nvme-subsystem/
nvme list-subsys
```

### View API response
```bash
pvesh get /nodes/<node>/storage/<storage>/status --output-format json
```

## Files

```
proxmox-multipath-display/
├── install.sh              # Main installer
├── install-gui.sh          # GUI component installer
├── uninstall.sh            # Uninstaller
├── src/
│   └── PVE/
│       ├── API2/
│       │   └── MultipathStatus.pm    # Standalone API endpoint
│       └── Storage/
│           └── Common/
│               └── MultipathStatusPlugin.pm  # Core plugin
├── www/
│   └── MultipathDisplay.js           # ExtJS GUI component
└── patches/
    └── storage-status-multipath.patch  # Status.pm patch
```

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions are welcome! Please submit issues and pull requests on GitHub.

