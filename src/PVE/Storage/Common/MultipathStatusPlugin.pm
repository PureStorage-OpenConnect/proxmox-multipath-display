package PVE::Storage::Common::MultipathStatusPlugin;

use strict;
use warnings;

use PVE::Tools qw(run_command file_read_firstline);

# Command paths
my $MULTIPATH = '/sbin/multipath';
my $MULTIPATHD = '/sbin/multipathd';
my $DMSETUP = '/sbin/dmsetup';
my $PVS = '/sbin/pvs';

# Helper to trim whitespace
sub trim {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/^\s+//;
    $str =~ s/\s+$//;
    return $str;
}

# Check if multipath tools are available
my $found_multipath;
sub assert_multipath_support {
    my ($noerr) = @_;
    return $found_multipath if $found_multipath;

    $found_multipath = -x $MULTIPATH && -x $MULTIPATHD;

    if (!$found_multipath) {
        die "error: no multipath support - please install multipath-tools\n" if !$noerr;
        warn "warning: no multipath support - please install multipath-tools\n";
    }
    return $found_multipath;
}

# Detect transport type for a device from sysfs
# Returns: 'iscsi', 'nvme', 'fc', 'sas', or 'unknown'
sub detect_transport {
    my ($device) = @_;

    return 'unknown' unless $device;

    # NVMe devices have nvme in the name
    return 'nvme' if $device =~ /^nvme/;

    my $dev_path = "/sys/block/$device/device";

    # For SCSI devices, check sysfs transport file
    my $transport = file_read_firstline("$dev_path/transport");
    return lc($transport) if $transport && $transport =~ /\S/;

    # Check for iSCSI session in sysfs path
    if (-d $dev_path) {
        # Check for iscsi_session link in parent directories
        if (-l "$dev_path/../../iscsi_session" || -d "$dev_path/../../iscsi_session") {
            return 'iscsi';
        }
        # Check symlink path for session info
        my $real_path = readlink($dev_path) // '';
        if ($real_path =~ /iscsi_session|session\d+/) {
            return 'iscsi';
        }
        if ($real_path =~ /fc_remote_ports|rport-/) {
            return 'fc';
        }
    }

    return 'unknown';
}

# Parse multipath -ll output into structured data
# Returns arrayref of device hashes
sub parse_multipath_output {
    my ($output) = @_;

    my @devices;
    my $current_device = undef;
    my $current_group = undef;

    for my $line (split /\n/, $output) {
        # Match device header line - two possible formats:
        # Format 1: "name (wwid) dm-X VENDOR,PRODUCT"
        # Format 2: "wwid dm-X VENDOR,PRODUCT" (wwid is the name, no parentheses)
        if ($line =~ /^(\S+)\s+\(([^)]+)\)\s+dm-(\d+)\s+(\S+)/) {
            # Format 1: name (wwid) dm-X VENDOR,PRODUCT
            push @devices, $current_device if $current_device;

            my ($name, $wwid, $dm_num, $vendor_product) = ($1, $2, $3, $4);
            my ($vendor, $product) = split /,/, $vendor_product, 2;

            $current_device = {
                name => $name,
                wwid => $wwid,
                dm => "dm-$dm_num",
                vendor => $vendor // '',
                product => $product // '',
                size => '',
                policy => '',
                selector => '',
                paths => [],
                pathGroups => [],
            };
            $current_group = undef;
            next;
        }
        elsif ($line =~ /^([0-9a-f]{20,})\s+dm-(\d+)\s+(\S+)/) {
            # Format 2: wwid dm-X VENDOR,PRODUCT (WWID is the name)
            push @devices, $current_device if $current_device;

            my ($wwid, $dm_num, $vendor_product) = ($1, $2, $3);
            my ($vendor, $product) = split /,/, $vendor_product, 2;

            $current_device = {
                name => $wwid,
                wwid => $wwid,
                dm => "dm-$dm_num",
                vendor => $vendor // '',
                product => $product // '',
                size => '',
                policy => '',
                selector => '',
                paths => [],
                pathGroups => [],
            };
            $current_group = undef;
            next;
        }

        next unless $current_device;

        # Match size line
        if ($line =~ /size=(\S+)\s+features='([^']*)'.*hwhandler='([^']*)'/) {
            $current_device->{size} = $1;
            $current_device->{features} = $2;
            $current_device->{hwhandler} = $3;
        }

        # Match policy line
        if ($line =~ /policy='([^']+)'.*prio=(\d+)\s+status=(\w+)/) {
            my ($policy, $prio, $status) = ($1, $2, $3);
            $current_device->{policy} = $policy unless $current_device->{policy};

            $current_group = {
                policy => $policy,
                priority => $prio,
                status => $status,
                paths => [],
            };
            push @{$current_device->{pathGroups}}, $current_group;
        }

        # Match path line: "|- 20:0:0:254 sdb 8:16 active ready running"
        # Format: [|`]- HCTL device major:minor state1 state2 state3
        if ($line =~ /[|` ]\s*[|`]-\s+(\d+:\d+:\d+:\d+)\s+(\S+)\s+\d+:\d+\s+(\w+)\s+(\w+)\s+(\w+)/) {
            my $path = {
                hctl => $1,
                device => $2,
                pathState => $3,  # e.g., "active"
                state => $4,      # e.g., "ready"
                dmState => $5,    # e.g., "running"
                transport => 'unknown',
                portal => '',
            };

            push @{$current_device->{paths}}, $path;
            push @{$current_group->{paths}}, $path if $current_group;
        }
    }

    push @devices, $current_device if $current_device;

    return \@devices;
}

# Get all multipath devices with their status (transport-agnostic)
sub get_all_multipath_devices {
    my ($class) = @_;

    assert_multipath_support();

    my @devices;

    eval {
        my $output = '';
        run_command(
            [$MULTIPATH, '-ll'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            timeout => 30,
        );

        @devices = @{parse_multipath_output($output)};

        # Detect transport for each path
        for my $device (@devices) {
            for my $path (@{$device->{paths}}) {
                $path->{transport} = detect_transport($path->{device});
            }
        }
    };

    return \@devices;
}

# Enrich paths with transport-specific information
# Auto-detects transport and looks up iSCSI session info
sub enrich_paths_with_transport_info {
    my ($class, $devices) = @_;

    # Pre-fetch iSCSI session info
    my $iscsi_sessions = $class->get_all_iscsi_sessions();

    for my $device (@$devices) {
        for my $path (@{$device->{paths}}) {
            my $dev = $path->{device};
            my $hctl = $path->{hctl};

            # Detect transport if unknown
            if (!$path->{transport} || $path->{transport} eq 'unknown') {
                $path->{transport} = detect_transport($dev);
            }

            # Enrich with iSCSI session info if applicable
            if ($path->{transport} eq 'iscsi' || $path->{transport} eq 'unknown') {
                if ($hctl && $iscsi_sessions->{$hctl}) {
                    my $session = $iscsi_sessions->{$hctl};
                    $path->{portal} = $session->{portal} // '';
                    $path->{target} = $session->{target} // '';
                    $path->{hostIface} = $session->{hostIface} // '';
                    $path->{transport} = 'iscsi';
                }
            }
        }
    }

    return $devices;
}

# Get all iSCSI sessions indexed by HCTL
sub get_all_iscsi_sessions {
    my ($class) = @_;

    my %sessions;

    eval {
        my $output = '';
        run_command(
            ['/usr/bin/iscsiadm', '-m', 'session', '-P', '3'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            timeout => 10,
            noerr => 1,
        );

        my $current_target = '';
        my $current_portal = '';
        my $current_iface = '';

        for my $line (split /\n/, $output) {
            if ($line =~ /Target:\s+(\S+)/) {
                $current_target = $1;
            }
            elsif ($line =~ /Current Portal:\s+(\S+)/) {
                $current_portal = $1;
                $current_portal =~ s/,\d+$//;  # Remove port suffix like ,1
            }
            elsif ($line =~ /Iface Netdev:\s+(\S+)/) {
                $current_iface = $1;
            }
            elsif ($line =~ /Host Number:\s+(\d+)\s+State:/) {
                # Store host number for matching
            }
            elsif ($line =~ /scsi(\d+)\s+Channel\s+(\d+)\s+Id\s+(\d+)\s+Lun:\s+(\d+)/) {
                # Normalize HCTL - remove leading zeros to match multipath output format
                my ($host, $channel, $id, $lun) = ($1, $2, $3, $4);
                $channel = int($channel);  # Remove leading zeros
                $id = int($id);
                $lun = int($lun);
                my $hctl = "$host:$channel:$id:$lun";
                $sessions{$hctl} = {
                    portal => $current_portal,
                    target => $current_target,
                    hostIface => $current_iface,
                };
            }
            # Also match "Attached scsi disk sdX" lines
            elsif ($line =~ /Attached scsi disk\s+(\S+)\s+/) {
                # This follows the scsi line, can be used for device matching
            }
        }
    };

    return \%sessions;
}

# Get multipath status for an LVM volume group (transport-agnostic)
sub get_lvm_multipath_status {
    my ($class, $vgname) = @_;

    my $result = {
        active => 0,
        devices => [],
        total_paths => 0,
        active_paths => 0,
        failed_paths => 0,
        vgname => $vgname,
        timestamp => time(),
    };

    return $result unless $vgname;

    eval {
        # Get physical volumes for this VG
        my $pvs_output = '';
        run_command(
            [$PVS, '--noheadings', '-o', 'pv_name,vg_name', '--separator', '|'],
            outfunc => sub { $pvs_output .= shift . "\n"; },
            errfunc => sub { },
            timeout => 10,
            noerr => 1,
        );

        my @pv_devices;
        for my $line (split /\n/, $pvs_output) {
            $line = trim($line);
            next unless $line =~ /\S/;
            my ($pv, $vg) = split /\|/, $line;
            $pv = trim($pv) if $pv;
            $vg = trim($vg) if $vg;
            if ($vg && $vg eq $vgname) {
                push @pv_devices, $pv;
            }
        }

        return $result unless @pv_devices;

        # Separate PVs into dm-multipath and NVMe devices
        my %mpath_wwids;
        my @nvme_pvs;

        for my $pv (@pv_devices) {
            my $dev_name = $pv;
            $dev_name =~ s|^/dev/||;

            # Check if NVMe device
            if ($dev_name =~ /^nvme\d+n\d+/) {
                push @nvme_pvs, $pv;
                next;
            }

            # Check for dm-multipath
            my $dm_name = $dev_name;
            $dm_name =~ s|^mapper/||;

            my $wwid = '';

            # If device name looks like a WWID
            if ($dm_name =~ /^([0-9a-f]{20,})$/i) {
                $wwid = $1;
            } else {
                # Try dmsetup
                eval {
                    my $dm_output = '';
                    run_command(
                        [$DMSETUP, 'info', '-c', '--noheadings', '-o', 'uuid', $dm_name],
                        outfunc => sub { $dm_output .= shift; },
                        errfunc => sub { },
                        timeout => 5,
                        noerr => 1,
                    );
                    $dm_output = trim($dm_output);
                    if ($dm_output =~ /^mpath-(.+)$/) {
                        $wwid = $1;
                    }
                };
            }

            if ($wwid) {
                $mpath_wwids{$wwid} = $pv;
            }
        }

        # Handle dm-multipath devices
        if (%mpath_wwids) {
            my $all_devices = $class->get_all_multipath_devices();

            for my $device (@$all_devices) {
                if ($mpath_wwids{$device->{wwid}} || $mpath_wwids{$device->{name}}) {
                    $device->{pv_path} = $mpath_wwids{$device->{wwid}} || $mpath_wwids{$device->{name}};

                    # Count paths
                    for my $path (@{$device->{paths}}) {
                        $result->{total_paths}++;
                        if ($path->{dmState} && $path->{dmState} eq 'running') {
                            $result->{active_paths}++;
                        } elsif ($path->{dmState} && $path->{dmState} =~ /faulty|failed/i) {
                            $result->{failed_paths}++;
                        }
                    }

                    push @{$result->{devices}}, $device;
                    $result->{active} = 1;
                }
            }

            # Enrich dm-multipath with transport-specific info
            $class->enrich_paths_with_transport_info($result->{devices});
        }

        # Handle NVMe native multipath devices
        if (@nvme_pvs) {
            my $nvme_devices = $class->get_nvme_multipath_for_devices(\@nvme_pvs);

            for my $device (@$nvme_devices) {
                # Count paths
                for my $path (@{$device->{paths}}) {
                    $result->{total_paths}++;
                    if ($path->{state} && $path->{state} eq 'live') {
                        $result->{active_paths}++;
                    } else {
                        $result->{failed_paths}++;
                    }
                }

                push @{$result->{devices}}, $device;
                $result->{active} = 1;
            }
        }
    };

    if ($@) {
        $result->{error} = $@;
    }

    return $result;
}

# Get NVMe native multipath info for a list of NVMe devices
sub get_nvme_multipath_for_devices {
    my ($class, $nvme_devices) = @_;

    my @result;
    return \@result unless $nvme_devices && @$nvme_devices;

    eval {
        # Get NVMe subsystem info
        my $nvme_output = '';
        run_command(
            ['/usr/sbin/nvme', 'list-subsys', '-o', 'json'],
            outfunc => sub { $nvme_output .= shift; },
            errfunc => sub { },
            timeout => 10,
            noerr => 1,
        );

        my $subsystems = [];
        eval {
            require JSON;
            my $data = JSON::decode_json($nvme_output);
            # nvme list-subsys returns array of hosts, each with Subsystems
            if (ref($data) eq 'ARRAY') {
                for my $host (@$data) {
                    if (ref($host) eq 'HASH' && $host->{Subsystems}) {
                        push @$subsystems, @{$host->{Subsystems}};
                    }
                }
            } elsif (ref($data) eq 'HASH' && $data->{Subsystems}) {
                $subsystems = $data->{Subsystems};
            }
        };

        for my $pv (@$nvme_devices) {
            my $dev_name = $pv;
            $dev_name =~ s|^/dev/||;

            # Get subsystem NQN from sysfs
            my $subsys_nqn = '';
            my $sysfs_path = "/sys/block/$dev_name/device/subsysnqn";
            if (-f $sysfs_path && open(my $fh, '<', $sysfs_path)) {
                $subsys_nqn = <$fh>;
                close($fh);
                chomp $subsys_nqn if $subsys_nqn;
            }
            next unless $subsys_nqn;

            for my $subsys (@$subsystems) {
                my $nqn = $subsys->{NQN} // $subsys->{SubsystemNQN} // '';
                next unless $nqn eq $subsys_nqn;

                my $subsys_name = $subsys->{Name} // '';

                # Read I/O policy from sysfs
                my $iopolicy = '';
                if ($subsys_name) {
                    my $policy_file = "/sys/class/nvme-subsystem/$subsys_name/iopolicy";
                    $iopolicy = file_read_firstline($policy_file) // '';
                }

                my $device = {
                    name => $dev_name,
                    pv_path => $pv,
                    subsystem => $subsys_name,
                    nqn => $nqn,
                    wwid => $nqn,
                    transport => 'nvme-tcp',
                    policy => $iopolicy,
                    paths => [],
                    pathGroups => [],
                };

                my $paths = $subsys->{Paths} // [];
                for my $path (@$paths) {
                    my $addr = $path->{Address} // '';
                    my ($traddr) = $addr =~ /traddr=([^,]+)/;
                    my ($trsvcid) = $addr =~ /trsvcid=(\d+)/;
                    my ($host_iface) = $addr =~ /host_iface=([^,]+)/;
                    my $portal = $traddr || '';

                    push @{$device->{paths}}, {
                        device => $path->{Name} // '',
                        controller => $path->{Name} // '',
                        transport => $path->{Transport} // 'tcp',
                        state => $path->{State} // 'unknown',
                        portal => $portal,
                        address => $addr,
                        target => $nqn,
                        hostIface => $host_iface // '',
                        pathState => $path->{State} // 'unknown',
                    };
                }

                if (@{$device->{paths}}) {
                    push @{$device->{pathGroups}}, {
                        status => 'active',
                        policy => $iopolicy || 'unknown',
                        paths => $device->{paths},
                    };
                }

                push @result, $device;
                last;
            }
        }
    };

    return \@result;
}

# Get multipath status for iSCSI multipath storage
# This is called from Status.pm patch for 'iscsimpath' storage type
sub get_iscsi_multipath_status {
    my ($class, $storeid, $scfg) = @_;

    my $result = {
        active => 0,
        devices => [],
        total_paths => 0,
        active_paths => 0,
        failed_paths => 0,
        storeid => $storeid,
        timestamp => time(),
    };

    eval {
        # Get target IQN from storage config
        my $target_str = $scfg->{iscsi_target} // $scfg->{target};
        return $result unless $target_str;

        my @targets = split /,/, $target_str;

        # Get all multipath devices
        my $all_devices = $class->get_all_multipath_devices();

        # Find which multipath devices belong to this iSCSI target
        # by matching session info
        my $output = '';
        run_command(
            ['/usr/bin/iscsiadm', '-m', 'session', '-P', '3'],
            outfunc => sub { $output .= shift . "\n"; },
            errfunc => sub { },
            timeout => 10,
            noerr => 1,
        );

        # Build a map of device -> (target, portal, hostIface)
        my %device_info;
        my $current_target = '';
        my $current_portal = '';
        my $current_iface = '';

        for my $line (split /\n/, $output) {
            if ($line =~ /Target:\s+(\S+)/) {
                $current_target = $1;
            }
            if ($line =~ /Current Portal:\s+(\S+)/) {
                $current_portal = $1;
                $current_portal =~ s/,\d+$//;
            }
            if ($line =~ /Iface Netdev:\s+(\S+)/) {
                $current_iface = $1;
            }
            if ($line =~ /Attached scsi disk\s+(\S+)/) {
                my $disk = $1;
                $device_info{$disk} = {
                    target => $current_target,
                    portal => $current_portal,
                    hostIface => $current_iface,
                };
            }
        }

        # Filter multipath devices that have paths belonging to our targets
        for my $device (@$all_devices) {
            my $has_matching_path = 0;

            for my $path (@{$device->{paths}}) {
                my $dev = $path->{device};
                if ($device_info{$dev}) {
                    my $dev_target = $device_info{$dev}{target};
                    if (grep { $_ eq $dev_target } @targets) {
                        $has_matching_path = 1;
                        $path->{portal} = $device_info{$dev}{portal};
                        $path->{target} = $device_info{$dev}{target};
                        $path->{hostIface} = $device_info{$dev}{hostIface};
                        $path->{transport} = 'iscsi';
                    }
                }
            }

            if ($has_matching_path) {
                $result->{active} = 1;

                # Count paths
                for my $path (@{$device->{paths}}) {
                    $result->{total_paths}++;
                    if ($path->{dmState} && $path->{dmState} eq 'running') {
                        $result->{active_paths}++;
                    } elsif ($path->{dmState} && $path->{dmState} =~ /faulty|failed/i) {
                        $result->{failed_paths}++;
                    }
                }

                push @{$result->{devices}}, $device;
            }
        }
    };

    if ($@) {
        $result->{error} = "$@";
    }

    return $result;
}

# Get multipath status for NVMe-TCP storage
sub get_nvme_multipath_status {
    my ($class, $storeid, $scfg) = @_;

    my $result = {
        active => 0,
        devices => [],
        total_paths => 0,
        active_paths => 0,
        failed_paths => 0,
        storeid => $storeid,
        timestamp => time(),
    };

    eval {
        # Get NVMe subsystem/NQN from storage config
        # Various possible config key names: nvme_subnqn, nvme_subsys_nqn, subsystem_nqn, nqn
        my $subsys_nqn = $scfg->{nvme_subnqn} // $scfg->{nvme_subsys_nqn} // $scfg->{subsystem_nqn} // $scfg->{nqn};
        return $result unless $subsys_nqn;

        # List NVMe controllers
        my $nvme_output = '';
        run_command(
            ['/usr/sbin/nvme', 'list-subsys', '-o', 'json'],
            outfunc => sub { $nvme_output .= shift; },
            errfunc => sub { },
            timeout => 10,
            noerr => 1,
        );

        # Parse JSON output to find paths for our subsystem
        my $subsystems = [];
        eval {
            require JSON;
            my $data = JSON::decode_json($nvme_output);
            # nvme list-subsys returns array of hosts, each with Subsystems
            if (ref($data) eq 'ARRAY') {
                for my $host (@$data) {
                    push @$subsystems, @{$host->{Subsystems} // []};
                }
            } else {
                # Fallback for older nvme-cli format
                $subsystems = $data->{Subsystems} // [];
            }
        };

        for my $subsys (@$subsystems) {
            my $nqn = $subsys->{NQN} // '';
            next unless $nqn eq $subsys_nqn;

            $result->{active} = 1;

            my $subsys_name = $subsys->{Name} // '';

            # Read I/O policy from sysfs
            my $iopolicy = '';
            if ($subsys_name) {
                my $policy_file = "/sys/class/nvme-subsystem/$subsys_name/iopolicy";
                $iopolicy = file_read_firstline($policy_file) // '';
            }

            my $device = {
                name => $subsys_name,
                wwid => $nqn,
                nqn => $nqn,
                vendor => '',
                product => '',
                policy => $iopolicy,
                paths => [],
                pathGroups => [],
            };

            # Set policy at result level too
            $result->{policy} = $iopolicy if $iopolicy;

            my $paths = $subsys->{Paths} // [];
            for my $path (@$paths) {
                my $ctrl_name = $path->{Name} // '';
                my $address = $path->{Address} // '';

                # Parse address to extract traddr (target address)
                my $portal = $address;
                if ($address =~ /traddr=([^,]+)/) {
                    $portal = $1;
                }
                # Also extract host interface
                my $host_iface = '';
                if ($address =~ /host_iface=([^,]+)/) {
                    $host_iface = $1;
                }

                my $path_info = {
                    device => $ctrl_name,
                    controller => $ctrl_name,
                    transport => $path->{Transport} // 'tcp',
                    portal => $portal,
                    address => $address,
                    hostIface => $host_iface,
                    state => $path->{State} // '',
                    pathState => $path->{State} // '',
                };

                push @{$device->{paths}}, $path_info;

                $result->{total_paths}++;
                if ($path->{State} && $path->{State} eq 'live') {
                    $result->{active_paths}++;
                } else {
                    $result->{failed_paths}++;
                }
            }

            push @{$result->{devices}}, $device;
        }
    };

    if ($@) {
        $result->{error} = "$@";
    }

    return $result;
}

# Main entry point - get multipath status for any storage type
sub get_multipath_status {
    my ($class, $storeid, $scfg) = @_;

    my $type = $scfg->{type} // '';

    if ($type eq 'iscsimpath') {
        return $class->get_iscsi_multipath_status($storeid, $scfg);
    } elsif ($type eq 'nvmetcp') {
        return $class->get_nvme_multipath_status($storeid, $scfg);
    } elsif ($type eq 'lvm' || $type eq 'lvmthin') {
        return $class->get_lvm_multipath_status($scfg->{vgname});
    }

    # For other types, return empty status
    return {
        active => 0,
        devices => [],
        total_paths => 0,
        active_paths => 0,
        failed_paths => 0,
    };
}

1;

