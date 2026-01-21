/*
 * Proxmox Multipath Display Plugin
 * Transport-agnostic multipath status display for Proxmox VE
 * Supports iSCSI, NVMe-TCP, FC, and other multipath transports
 */

// Transport icons and labels
const TRANSPORT_CONFIG = {
    'iscsi': { icon: 'fa-database', label: 'iSCSI', color: '#337ab7' },
    'nvme': { icon: 'fa-bolt', label: 'NVMe', color: '#5cb85c' },
    'nvme-tcp': { icon: 'fa-bolt', label: 'NVMe-TCP', color: '#5cb85c' },
    'nvme-rdma': { icon: 'fa-bolt', label: 'NVMe-RDMA', color: '#5cb85c' },
    'nvme-fc': { icon: 'fa-bolt', label: 'NVMe-FC', color: '#5cb85c' },
    'tcp': { icon: 'fa-bolt', label: 'NVMe-TCP', color: '#5cb85c' },  // nvme list-subsys returns 'tcp'
    'rdma': { icon: 'fa-bolt', label: 'NVMe-RDMA', color: '#5cb85c' },
    'fc': { icon: 'fa-plug', label: 'Fibre Channel', color: '#f0ad4e' },
    'sas': { icon: 'fa-link', label: 'SAS', color: '#5bc0de' },
    'unknown': { icon: 'fa-question-circle', label: 'Unknown', color: '#999' },
};

// Get transport display info
function getTransportInfo(transport) {
    return TRANSPORT_CONFIG[transport] || TRANSPORT_CONFIG['unknown'];
}

// Hook into the storage Summary panel to add multipath status
(function() {
    function ensureMultipathStyles() {
        if (Ext.get('pve-multipath-styles')) return;

        Ext.DomHelper.append(Ext.getHead(), {
            tag: 'style',
            id: 'pve-multipath-styles',
            html: [
                '.pve-mpath {',
                '  --pve-mpath-surface: var(--pwt-panel-background, #f8f8f8);',
                '  --pve-mpath-border: var(--pwt-chart-grid-stroke, #e0e0e0);',
                '  --pve-mpath-header-bg: var(--pwt-gauge-back, #e8e8e8);',
                '  --pve-mpath-summary-bg: var(--pwt-gauge-back, #f0f0f0);',
                '  --pve-mpath-muted: var(--pwt-text-color, #666);',
                '  --pve-mpath-accent: var(--pwt-chart-primary, #337ab7);',
                '  --pve-mpath-code-bg: #2d2d2d;',
                '  --pve-mpath-code-fg: #f8f8f2;',
                '}',
                '.pve-mpath .pve-mpath-device {',
                '  margin-bottom: 15px;',
                '  padding: 10px;',
                '  background: var(--pve-mpath-surface);',
                '  border: 1px solid var(--pve-mpath-border);',
                '  border-radius: 4px;',
                '}',
                '.pve-mpath .pve-mpath-muted {',
                '  color: var(--pve-mpath-muted);',
                '}',
                '.pve-mpath .pve-mpath-accent {',
                '  color: var(--pve-mpath-accent);',
                '}',
                '.pve-mpath .pve-mpath-summary {',
                '  margin-top: 10px;',
                '  padding: 8px;',
                '  background: var(--pve-mpath-summary-bg);',
                '  border-radius: 4px;',
                '}',
                '.pve-mpath .pve-mpath-empty {',
                '  margin-top: 15px;',
                '  padding: 10px;',
                '  background: var(--pve-mpath-surface);',
                '  border: 1px solid var(--pve-mpath-border);',
                '  border-radius: 3px;',
                '}',
                '.pve-mpath .pve-mpath-command {',
                '  display: block;',
                '  margin-top: 8px;',
                '  padding: 8px;',
                '  background: var(--pve-mpath-code-bg);',
                '  color: var(--pve-mpath-code-fg);',
                '  border-radius: 3px;',
                '}',
                '.pve-mpath .pve-mpath-table {',
                '  width: 100%;',
                '  border-collapse: collapse;',
                '  margin-top: 8px;',
                '}',
                '.pve-mpath .pve-mpath-table th,',
                '.pve-mpath .pve-mpath-table td {',
                '  padding: 6px;',
                '  border: 1px solid var(--pve-mpath-border);',
                '  text-align: left;',
                '}',
                '.pve-mpath .pve-mpath-table thead tr {',
                '  background: var(--pve-mpath-header-bg);',
                '}',
            ].join('\n'),
        });
    }

    // Store the original initComponent
    let originalInit = PVE.storage.Summary.prototype.initComponent;

    PVE.storage.Summary.prototype.initComponent = function() {
        let me = this;

        // Call the original initComponent first
        originalInit.apply(me, arguments);

        // After render, check if this storage has multipath backing
        me.on('afterrender', function() {
            let storeid = me.pveSelNode?.data?.storage;
            let nodename = me.pveSelNode?.data?.node;

            if (!storeid) return;

            // Check storage type and if it has multipathStatus
            Proxmox.Utils.API2Request({
                url: '/storage/' + storeid,
                method: 'GET',
                success: function(response) {
                    let storageConfig = response.result.data;
                    // Support multiple storage types that might use multipath
                    let multipathTypes = ['iscsimpath', 'nvmetcp', 'lvm', 'lvmthin'];
                    if (multipathTypes.includes(storageConfig.type)) {
                        PVE.storage.Summary.prototype.addMultipathStatusPanel.call(
                            me, storageConfig, storeid, nodename
                        );
                    }
                },
                failure: function() {
                    // Silently ignore
                },
            });
        }, me, { single: true });
    };

    PVE.storage.Summary.prototype.addMultipathStatusPanel = function(storageConfig, storeid, nodename) {
        let me = this;

        ensureMultipathStyles();

        // Do not add if already exists
        if (me.down('#multipathStatus')) return;

        // Create the multipath status panel
        let multipathPanel = Ext.create('Ext.panel.Panel', {
            title: gettext('Multipath Paths'),
            iconCls: 'fa fa-road',
            bodyPadding: 10,
            margin: '10 0 0 0',
            itemId: 'multipathStatus',
            html: '<div style="padding: 10px;"><i class="fa fa-spinner fa-spin"></i> ' +
                  gettext('Loading...') + '</div>',
        });

        me.add(multipathPanel);

        // Load multipath status
        PVE.storage.Summary.prototype.loadMultipathStatus.call(
            me, storageConfig, storeid, nodename
        );
    };

    PVE.storage.Summary.prototype.loadMultipathStatus = function(storageConfig, storeid, nodename) {
        let me = this;
        let multipathPanel = me.down('#multipathStatus');
        if (!multipathPanel) return;

        if (!nodename) {
            PVE.storage.Summary.prototype.renderMultipathStatus.call(
                me, multipathPanel, storageConfig, { active: false }, null
            );
            return;
        }

        // Get storage status from node API - includes multipathStatus
        Proxmox.Utils.API2Request({
            url: '/nodes/' + nodename + '/storage/' + storeid + '/status',
            method: 'GET',
            success: function(response) {
                let statusData = response.result.data;
                let pathData = null;

                if (statusData.multipathStatus && statusData.multipathStatus.devices) {
                    pathData = statusData.multipathStatus.devices;
                }

                PVE.storage.Summary.prototype.renderMultipathStatus.call(
                    me, multipathPanel, storageConfig, statusData, pathData
                );
            },
            failure: function() {
                PVE.storage.Summary.prototype.renderMultipathStatus.call(
                    me, multipathPanel, storageConfig, { active: false }, null
                );
            },
        });
    };

    PVE.storage.Summary.prototype.renderMultipathStatus = function(panel, storageConfig, statusData, pathData) {
        let html = '<div class="pve-mpath"><table class="pve-infotable" style="width: 100%;">';

        // Determine storage type display
        let hasMultipath = statusData.multipathStatus &&
                           statusData.multipathStatus.devices &&
                           statusData.multipathStatus.devices.length > 0;

        if (storageConfig.type === 'lvm' || storageConfig.type === 'lvmthin') {
            if (hasMultipath) {
                // Detect primary transport from devices
                let primaryTransport = 'unknown';
                if (pathData && pathData.length > 0 && pathData[0].paths && pathData[0].paths.length > 0) {
                    primaryTransport = pathData[0].paths[0].transport || 'unknown';
                }
                let transportInfo = getTransportInfo(primaryTransport);
                let storageTypeLabel = 'LVM on Multipath ' + transportInfo.label;

                html += '<tr><td style="width: 150px;">' + gettext('Storage Type') + ':</td><td>' +
                    '<span style="color: ' + transportInfo.color + ';"><i class="fa ' + transportInfo.icon + '"></i> ' +
                    storageTypeLabel + '</span></td></tr>';
                html += '<tr><td>' + gettext('Volume Group') + ':</td><td>' +
                    '<code>' + Ext.htmlEncode(storageConfig.vgname) + '</code></td></tr>';
            } else {
                panel.setHidden(true);
                return;
            }
        } else {
            // Direct multipath storage (iscsimpath, nvmetcp, etc.)
            let transportInfo = getTransportInfo(storageConfig.type === 'nvmetcp' ? 'nvme' : 'iscsi');

            html += '<tr><td style="width: 150px;">' + gettext('Storage Type') + ':</td><td>' +
                '<span style="color: ' + transportInfo.color + ';"><i class="fa ' + transportInfo.icon + '"></i> ' +
                transportInfo.label + ' Multipath</span></td></tr>';

            if (storageConfig.iscsi_portal) {
                html += '<tr><td>' + gettext('Portal') + ':</td><td>' +
                    '<code>' + Ext.htmlEncode(storageConfig.iscsi_portal) + '</code></td></tr>';
            }
            if (storageConfig.iscsi_target) {
                html += '<tr><td>' + gettext('Target') + ':</td><td>' +
                    '<code>' + Ext.htmlEncode(storageConfig.iscsi_target) + '</code></td></tr>';
            }
        }

        html += '</table>';

        // Render path data if available
        if (pathData && pathData.length > 0) {
            html += '<div style="margin-top: 15px;">';
            html += '<div style="font-weight: bold; margin-bottom: 10px;"><i class="fa fa-road"></i> ' +
                    gettext('Multipath Devices') + '</div>';

            let storageType = storageConfig.type;
            pathData.forEach(function(device) {
                html += PVE.storage.Summary.prototype.renderMultipathDevice(device, storageType);
            });

            // Summary - count total and active paths
            let totalPaths = 0, activePaths = 0;
            pathData.forEach(function(device) {
                if (device.paths) {
                    device.paths.forEach(function(path) {
                        totalPaths++;
                        // NVMe uses 'live' state, dm-multipath uses 'running' dmState
                        if (path.state === 'live' || path.dmState === 'running') {
                            activePaths++;
                        }
                    });
                }
            });

            html += '<div class="pve-mpath-summary">';
            if (activePaths === totalPaths) {
                html += '<span style="color: #5cb85c;"><i class="fa fa-check-circle"></i> ' +
                        activePaths + '/' + totalPaths + ' ' + gettext('paths active') + '</span>';
            } else {
                html += '<span style="color: #f0ad4e;"><i class="fa fa-exclamation-triangle"></i> ' +
                        activePaths + '/' + totalPaths + ' ' + gettext('paths active') + '</span>';
            }
            html += '</div>';
            html += '</div>';
        } else {
            html += '<div class="pve-mpath-empty">';
            html += '<div class="pve-mpath-muted"><i class="fa fa-info-circle"></i> ' +
                    gettext('Path details not available. Run on the node:') + '</div>';
            html += '<code class="pve-mpath-command">multipath -ll</code>';
            html += '</div>';
        }

        html += '</div>';
        panel.update(html);
    };

    PVE.storage.Summary.prototype.renderMultipathDevice = function(device, storageType) {
        let html = '<div class="pve-mpath-device">';

        // Detect NVMe native multipath based on storage type or device properties
        // LVM on NVMe will have nqn/subsystem set, or paths starting with 'nvme'
        let hasNvmePaths = device.paths && device.paths.length > 0 &&
            device.paths[0].device && device.paths[0].device.startsWith('nvme');
        let isNvmeNative = storageType === 'nvmetcp' ||
            !!device.nqn ||
            (device.subsystem && device.subsystem.startsWith('nvme-subsys')) ||
            device.transport === 'nvme-tcp' ||
            (device.name && device.name.startsWith('nvme')) ||
            hasNvmePaths;
        let mpathType = isNvmeNative ? 'Native NVMe' : 'dm-multipath';
        let mpathIcon = isNvmeNative ? 'fa-bolt' : 'fa-sitemap';

        // Get policy from pathGroups if not set directly
        let policy = device.policy;
        if (!policy && device.pathGroups && device.pathGroups.length > 0) {
            policy = device.pathGroups[0].policy;
        }

        // Device header
        html += '<div style="font-weight: bold; margin-bottom: 8px;">';
        if (isNvmeNative) {
            html += '<i class="fa fa-bolt" style="color: #5cb85c;"></i> /dev/' + Ext.htmlEncode(device.name);
        } else {
            html += '<i class="fa fa-hdd-o"></i> /dev/mapper/' + Ext.htmlEncode(device.name);
        }
        if (device.size) {
            html += ' <span class="pve-mpath-muted" style="font-weight: normal;">(' + Ext.htmlEncode(device.size) + ')</span>';
        }
        if (device.pv_path) {
            html += ' <span class="pve-mpath-accent" style="font-weight: normal;">&rarr; PV: ' + Ext.htmlEncode(device.pv_path) + '</span>';
        }
        html += '</div>';

        // Device details - different for NVMe vs SCSI
        html += '<div class="pve-mpath-muted" style="font-size: 0.9em; margin-bottom: 8px;">';
        if (isNvmeNative) {
            html += 'NQN: ' + Ext.htmlEncode(device.nqn || device.wwid || 'unknown');
            if (device.subsystem) {
                html += ' | Subsystem: ' + Ext.htmlEncode(device.subsystem);
            }
        } else {
            html += 'WWID: ' + Ext.htmlEncode(device.wwid || 'unknown');
            if (device.vendor) {
                html += ' | Vendor: ' + Ext.htmlEncode(device.vendor);
            }
        }
        html += ' | <span style="color: #5cb85c;"><i class="fa ' + mpathIcon + '"></i> ' + mpathType + '</span>';
        if (policy) {
            html += ' | Policy: ' + Ext.htmlEncode(policy);
        }
        html += '</div>';

        // Path table - adjust columns based on multipath type
        if (device.paths && device.paths.length > 0) {
            html += '<table class="pve-mpath-table">';
            html += '<thead><tr>';
            html += '<th>' + gettext('Device') + '</th>';
            if (isNvmeNative) {
                html += '<th>' + gettext('Controller') + '</th>';
            } else {
                html += '<th>HCTL</th>';
            }
            html += '<th>' + gettext('Transport') + '</th>';
            html += '<th>' + gettext('Portal/Address') + '</th>';
            html += '<th>' + gettext('Interface') + '</th>';
            html += '<th>' + gettext('State') + '</th>';
            html += '</tr></thead><tbody>';

            device.paths.forEach(function(path) {
                let stateColor = '#5cb85c';
                let stateIcon = 'fa-check-circle';
                // 'ready'/'active' for iSCSI/SCSI, 'live' for NVMe
                let pathOk = path.state === 'ready' || path.state === 'active' || path.state === 'live';
                if (!pathOk) {
                    stateColor = '#d9534f';
                    stateIcon = 'fa-times-circle';
                }

                let transportInfo = getTransportInfo(path.transport || 'unknown');

                html += '<tr>';
                html += '<td><code>/dev/' + Ext.htmlEncode(path.device) + '</code></td>';
                if (isNvmeNative) {
                    // Show controller name for NVMe (e.g., nvme0, nvme1)
                    html += '<td>' + Ext.htmlEncode(path.controller || '-') + '</td>';
                } else {
                    html += '<td>' + Ext.htmlEncode(path.hctl || '-') + '</td>';
                }
                html += '<td style="color: ' + transportInfo.color + ';">';
                html += '<i class="fa ' + transportInfo.icon + '"></i> ' + transportInfo.label;
                html += '</td>';
                html += '<td>' + Ext.htmlEncode(path.portal || '-') + '</td>';
                html += '<td>' + Ext.htmlEncode(path.hostIface || '-') + '</td>';
                html += '<td style="color: ' + stateColor + ';">';
                html += '<i class="fa ' + stateIcon + '"></i> ' + Ext.htmlEncode(path.state);
                html += '</td>';
                html += '</tr>';
            });

            html += '</tbody></table>';
        }

        html += '</div>';
        return html;
    };
})();

