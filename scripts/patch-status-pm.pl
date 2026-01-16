#!/usr/bin/perl
# Smart patcher for Status.pm that finds the right location dynamically

use strict;
use warnings;

my $STATUS_PM = '/usr/share/perl5/PVE/API2/Storage/Status.pm';
my $BACKUP_DIR = '/var/lib/multipath-display-plugin';
my $BACKUP_FILE = "$BACKUP_DIR/Status.pm.original";
my $MARKER = '# MULTIPATH-DISPLAY-PATCHED';

# Check if already patched
open(my $fh, '<', $STATUS_PM) or die "Cannot open $STATUS_PM: $!\n";
my $content = do { local $/; <$fh> };
close($fh);

if ($content =~ /$MARKER/) {
    print "Status.pm is already patched.\n";
    exit 0;
}

# Backup original
if (! -f $BACKUP_FILE) {
    system("mkdir -p $BACKUP_DIR");
    system("cp $STATUS_PM $BACKUP_FILE");
    print "Backed up original Status.pm\n";
}

# Find the insertion point - look for the pattern in the status method
# We want to insert AFTER: raise_param_exc({ storage => "No such storage." })
#                           if !defined($data);
# and BEFORE: return $data;

my $multipath_code = <<'MPATH_CODE';

        # Multipath Display: Add multipath status for supported storage types
        my $mpath_scfg = PVE::Storage::storage_config($cfg, $param->{storage});
        my $mpath_type = $mpath_scfg->{type};

        # Direct multipath storage types (register your storage type here)
        my %multipath_types = (
            'iscsimpath' => 'PVE::Storage::Custom::ISCSIMultipathPlugin',
            'nvmetcp' => 'PVE::Storage::Custom::NVMeTCPPlugin',
        );

        if (my $plugin = $multipath_types{$mpath_type}) {
            eval {
                eval "require $plugin";
                if (!$@) {
                    $data->{multipathStatus} = $plugin->get_multipath_status($param->{storage}, $mpath_scfg);
                }
            };
            warn "Failed to get multipath status: $@" if $@;
        }

        # LVM storages - check if backed by multipath devices
        if (($mpath_type eq 'lvm' || $mpath_type eq 'lvmthin') && $mpath_scfg->{vgname}) {
            eval {
                require PVE::Storage::Common::MultipathStatusPlugin;
                my $lvm_mpath_status = PVE::Storage::Common::MultipathStatusPlugin->get_lvm_multipath_status($mpath_scfg->{vgname});
                $data->{multipathStatus} = $lvm_mpath_status if $lvm_mpath_status && @{$lvm_mpath_status->{devices}};
            };
            # Silently ignore failures - not all LVM storages are on multipath
        }
MPATH_CODE

# Find the right place to insert
# Look for the pattern: if !defined($data); followed by return $data;
if ($content =~ /(.*if\s+!defined\(\$data\);?\s*\n)(\s*)(return\s+\$data;)/s) {
    my $before = $1;
    my $indent = $2;
    my $return_statement = $3;
    my $after = $';  # Everything after the match
    
    # Insert our code between the check and the return
    my $new_content = $before . $multipath_code . "\n" . $indent . $return_statement . $after;
    
    # Add marker at the top
    $new_content =~ s/(package PVE::API2::Storage::Status;)/$MARKER\n$1/;
    
    # Write the patched file
    open(my $out, '>', $STATUS_PM) or die "Cannot write to $STATUS_PM: $!\n";
    print $out $new_content;
    close($out);
    
    print "✓ Successfully patched Status.pm\n";
    print "  Inserted multipath code before 'return \$data;'\n";
    exit 0;
} else {
    print "✗ Could not find insertion point in Status.pm\n";
    print "  Looking for pattern: if !defined(\$data); ... return \$data;\n";
    print "  Manual patching required.\n";
    exit 1;
}

