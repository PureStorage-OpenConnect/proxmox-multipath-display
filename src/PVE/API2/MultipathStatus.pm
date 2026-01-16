package PVE::API2::MultipathStatus;

use strict;
use warnings;

use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::Storage;
use PVE::Tools qw(run_command);

use base qw(PVE::RESTHandler);

# Get multipath status for any storage (transport-agnostic)
__PACKAGE__->register_method({
    name => 'get_multipath_status',
    path => '{storage}',
    method => 'GET',
    description => "Get multipath status for a storage.",
    permissions => {
        check => ['perm', '/storage/{storage}', ['Datastore.Audit']],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => {
        type => 'object',
        properties => {
            uses_multipath => { type => 'boolean' },
            active => { type => 'boolean' },
            total_paths => { type => 'integer' },
            active_paths => { type => 'integer' },
            failed_paths => { type => 'integer' },
            policy => { type => 'string' },
            transports => { 
                type => 'array',
                items => { type => 'string' },
                description => 'List of transport types in use',
            },
            devices => {
                type => 'array',
                items => {
                    type => 'object',
                    properties => {
                        name => { type => 'string' },
                        wwid => { type => 'string' },
                        size => { type => 'string' },
                        policy => { type => 'string' },
                        paths => {
                            type => 'array',
                            items => {
                                type => 'object',
                                properties => {
                                    device => { type => 'string' },
                                    hctl => { type => 'string' },
                                    transport => { type => 'string' },
                                    portal => { type => 'string' },
                                    state => { type => 'string' },
                                    dmState => { type => 'string' },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $storeid = $param->{storage};
        my $cfg = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $storeid);

        my $result = {
            uses_multipath => 0,
            active => 0,
            total_paths => 0,
            active_paths => 0,
            failed_paths => 0,
            policy => '',
            transports => [],
            devices => [],
        };

        # Try to load the unified multipath plugin
        eval {
            require PVE::Storage::Common::MultipathStatusPlugin;
        };
        if ($@) {
            warn "MultipathStatusPlugin not available: $@";
            return $result;
        }

        my $mpath_plugin = 'PVE::Storage::Common::MultipathStatusPlugin';

        # Handle different storage types
        my $type = $scfg->{type};

        # Use MultipathStatusPlugin for all storage types - it's transport-agnostic
        if ($type eq 'iscsimpath' || $type eq 'nvmetcp') {
            $result->{uses_multipath} = 1;
            eval {
                my $status = $mpath_plugin->get_multipath_status($storeid, $scfg);
                _merge_status($result, $status);
            };
            warn "Failed to get multipath status for $type: $@" if $@;
        }
        # LVM storages - check if backed by multipath
        elsif (($type eq 'lvm' || $type eq 'lvmthin') && $scfg->{vgname}) {
            eval {
                my $status = $mpath_plugin->get_lvm_multipath_status($scfg->{vgname});
                if ($status && $status->{devices} && @{$status->{devices}}) {
                    $result->{uses_multipath} = 1;
                    _merge_status($result, $status);
                }
            };
        }

        # Collect unique transports
        my %transports;
        for my $device (@{$result->{devices}}) {
            for my $path (@{$device->{paths}}) {
                $transports{$path->{transport}}++ if $path->{transport};
            }
        }
        $result->{transports} = [keys %transports];

        return $result;
    },
});

# Helper to merge status from a plugin into result
sub _merge_status {
    my ($result, $status) = @_;
    return unless $status;

    $result->{active} = $status->{active} ? 1 : 0;
    $result->{total_paths} = $status->{total_paths} // 0;
    $result->{active_paths} = $status->{active_paths} // 0;
    $result->{failed_paths} = $status->{failed_paths} // 0;
    $result->{policy} = $status->{policy} // '';
    $result->{devices} = $status->{devices} // [];
}

1;

