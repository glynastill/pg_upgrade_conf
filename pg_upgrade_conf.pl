#!/usr/bin/perl

# Script: pg_upgrade_conf.pl
# Copyright: 28/12/2014: Glyn Astill <glyn@8kb.co.uk>
# Requires: Perl 5.10.1+
#
# This script is a command-line utility to transplant PostgreSQL
# server settings from one conf file or server to another.
# Primarily intended for copying current settings in postgresql.conf
# into the default copy provided by a newer version to maintain 
# information regarding new settings and defaults.
#
# This script is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script. If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use DBI;
use v5.10.1;
use File::Copy;
use Getopt::Long qw/GetOptions/;
Getopt::Long::Configure qw/no_ignore_case/;

use constant false => 0;
use constant true => 1;

my $g_debug = false; 
my %g_gucs;
my %g_gucs_src;
my $g_page_size = 8192;
my $g_wal_segment_size = 2048;
my $g_wal_segment = sizePretty(8192*2048);

# Settings that map onto obsolete settings
#                 <new_setting>                                <old_setting> <pretty modifier> <pretty units> <internal modifier>
my %g_gucs_map = (max_wal_size                            => [ split(' ', "checkpoint_segments *$g_wal_segment *1")   ]);

# Obsolete settings , last version present and successor
my %g_gucs_obs = (max_fsm_pages                           => [ qw(8.3)                         ], 
                  max_fsm_relations                       => [ qw(8.3)                         ], 
                  ssl_renegotiation_limit                 => [ qw(9.3)                         ], 
                  checkpoint_segments                     => [ qw(9.3 max_wal_size)             ]);

my $g_non_default_count = 0;
my $g_change_count = 0;
my $g_usage = 'pg_upgrade_conf.pl { -f <path> [ -a <path> ] | -c <conninfo> } { -F <path> | -C <conninfo> }

-f --old_file           Path to the old configuration file to read settings from
-a --old_auto_file      Path to the old auto configuration file to read settings set via ALTER SYSTEM from
-c --old_conninfo       Conninfo of the old server to read settings from
-F --new_file           Path to the new configuration file to alter
-C --new_conninfo       Conninfo of the new server to apply settings via ALTER SYSTEM';


use vars qw{%opt};
die $g_usage unless GetOptions(\%opt, 'old_file|f=s', 'old_auto_file|a=s', 'new_file|F=s', 'old_conninfo|c=s', 'new_conninfo|C=s') 
    and keys %opt and ! @ARGV;

if (defined($opt{old_file})) {
    loadSourceFromFile($opt{old_file});
    if (defined($opt{old_auto_file})) {
        loadSourceFromFile($opt{old_auto_file});
    }
}
elsif (defined($opt{old_conninfo})) {
    loadSourceFromConninfo($opt{old_conninfo});
}

print "Found $g_non_default_count non-default settings in old configuration\n";

if (defined($opt{new_file})) {
    $g_change_count = modifyNewFile($opt{new_file});
}
elsif (defined($opt{new_conninfo})) {
    $g_change_count = modifyNewConninfo($opt{new_conninfo});
    if ($g_change_count > 0) {
        print "WARNING: $g_change_count changes made to postgresql.auto.conf using ALTER SYSTEM; these will override any values set in postgresql.conf\n";
    }
}

print "Made $g_change_count changes to new configuration\n";

sub loadSourceFromFile {
    my $old_file = shift;
    my $key;
    my $value;
    my $src;
    my @fields;

    if (open(OLDFILE, "<", $old_file)) {
        foreach (<OLDFILE>) {
            chomp $_;
            unless ($_ =~ /^#/) {
                for ($_) {
                    s/\r//;
                    s/#(?=(?:(?:[^']|[^"]*+'){2})*+[^']|[^"]*+\z).*//;
                }
                if (length(trim($_))) {
                    @fields = split('=', $_, 2);
                    $key = trim($fields[0]);
                    $value = trim($fields[1]);
                    $src = $old_file;
                    if ($g_debug) { 
                        print "DEBUG: Source file key = $key value = $value src = $src\n";
                    }
                    if (exists($g_gucs{$key})) {
                        print "WARNING: Source value for $key specified more than once, overwriting $g_gucs{$key} from $g_gucs_src{$key} with $value from $src\n";
                    }
                    else {
                        $g_non_default_count++;
                    }
                    $g_gucs{$key} = $value;
                    $g_gucs_src{$key} = $src;
                }
            }
        }
        close (OLDFILE);
    }
    else {
        print "ERROR: Unable to open $old_file for reading\n";
    }
}

sub loadSourceFromConninfo {
    my $old_conninfo = shift;

    my $key;
    my $value;
    my $src;
    my @fields;

    my $dsn;
    my $dbh;
    my $sth;
    my $query;

    $dsn = "DBI:Pg:$old_conninfo;";
    eval {
        $dbh = DBI->connect($dsn, '', '', {RaiseError => 1});
        $query = "SELECT name, CASE vartype WHEN 'string' THEN quote_literal(reset_val) ELSE reset_val END, sourcefile 
                    FROM pg_catalog.pg_settings WHERE boot_val <> reset_val AND source = 'configuration file'
                    AND context <> 'internal'";
        $sth = $dbh->prepare($query);
        $sth->execute();
        while (my @fields = $sth->fetchrow) {
            $key = trim($fields[0]);
            $value = trim($fields[1]);
            $src = trim($fields[2]);
            if ($g_debug) { 
                print "DEBUG: Source setting key = $key value = $value src = $src\n";
            }
            $g_gucs{$key} = $value;
            $g_gucs_src{$key} = $src;
            $g_non_default_count++;
        }
        $sth->finish;
    };
    if ($@) {
        print "ERROR: $@\n";
    }
}

sub modifyNewFile {
    my $new_file = shift;
    my $key;
    my $value;
    my @lines;
    my @fields;
    my $pushed;
    my $comment;
    my $setting = 0;
    my $change_count = 0;
    my $not_written = false;

    if (open(NEWFILE, "<", $new_file)) {
        foreach (<NEWFILE>) {
            chomp $_;
            $pushed = false;
            $comment = true;
            if ($_ =~ /=/) {
                @fields = split('=', $_, 2);
                $key = $fields[0];
                $key =~ s/^#(.*)$/$1/;
                $key = trim($key);
                $value = trim($fields[1]);
                for ($value) {
                    s/\r//;
                    s/#(?=(?:(?:[^']|[^"]*+'){2})*+[^']|[^"]*+\z).*//;
                }
                $value = trim($value);
                if ($g_debug) { 
                    print "DEBUG: Target file key = $key value = $value\n";
                }
                if (!exists($g_gucs{$key}) && exists($g_gucs_map{$key}) && exists($g_gucs{$g_gucs_map{$key}[0]})) {
                    $g_gucs{$key} = eval($g_gucs{$g_gucs_map{$key}[0]} . $g_gucs_map{$key}[1]) . (defined($g_gucs_map{$key}[2])?"$g_gucs_map{$key}[2]":"");
                    $g_gucs_src{$key} .=  "(mapped from $g_gucs_map{$key}[0] = $g_gucs{$g_gucs_map{$key}[0]})";
                    push(@lines, "# $g_gucs_map{$key}[0]  =  $g_gucs{$g_gucs_map{$key}[0]}    # Obsoleted by $key as of pg $g_gucs_obs{$g_gucs_map{$key}[0]}[0] by $key = $g_gucs_map{$key}[0]$g_gucs_map{$key}[1] $g_gucs_map{$key}[2]");
                    $g_gucs{$g_gucs_map{$key}[0]} = '[written]';
		}
                if (exists($g_gucs{$key})) {
                    if (($_ !~ /^#/) && ($value eq $g_gucs{$key})) {
                            $setting++;
                            # Setting is already present and not commented out/default
                            print "$setting) Not setting $key : the values are already the same $value = $g_gucs{$key}\n";
                            $g_gucs{$key} = '[written]';
                    }
                    else { 
                        if ($_ !~ /^#/) {
                            $_ = '#' . $_;
                            $comment = false;
                        }
                        push(@lines, $_);
                        $pushed = true;
                        if ($g_gucs{$key} ne '[written]'){
                            $setting++;
                            print "$setting) Setting $key to $g_gucs{$key} : was " . (($comment)?"commented out / set to default":"set to") . " $value\n";
                            push(@lines, $key . ' = ' . $g_gucs{$key});
                            $g_gucs{$key} = '[written]';
                            $change_count++;
                        }
                    }
                }
            }
            unless ($pushed) {
                    push(@lines, $_);
            }
        }
        close(NEWFILE);

        foreach $key (keys %g_gucs) {
            if ($g_gucs{$key} ne '[written]') {
                $not_written = true;
                last;
            }
        }

        if ($not_written) {
            push(@lines, '');
            push(@lines, '#' . '-'x78);
            push(@lines, '# Unmatched settings written by pg_upgrade_conf.pl on ' . currentTimestamp());
            push(@lines, '#' . '-'x78);
            foreach $key (keys %g_gucs) {
                if ($g_gucs{$key} ne '[written]') {
                    $setting++;
                    if (exists($g_gucs_obs{$key})) {
                        print "$setting) No place holder for setting $key : obsolete as of pg $g_gucs_obs{$key}[0] adding commented setting # $key = $g_gucs{$key}\n";
                        push(@lines, "# $key = $g_gucs{$key}    # Obsolete as of pg $g_gucs_obs{$key}[0]");
                    }
                    else {
                        print "$setting) No place holder for setting $key : adding setting $key = $g_gucs{$key}\n";
                        push(@lines, "$key = $g_gucs{$key}");
                    }
                }
            }
        }

        copy($new_file, $new_file . '.bak');

        if (open(NEWFILE, ">", $new_file)) {
            foreach (@lines) {
                if ($g_debug) {
                    print "DEBUG: Line = $_\n";
                }
                print NEWFILE "$_\n";
            }
            close(NEWFILE);
        }
        else {
            print "ERROR: Unable to open $new_file for writing\n";
        }
    }
    else {
        print "ERROR: Unable to open $new_file for reading\n";
    }
    return $change_count;
}

sub modifyNewConninfo {
    my $new_conninfo = shift;
    my $version;
    my $key;
    my $value;

    my $setting = 0;
    my $change_count = 0;
    my $dsn;
    my $dbh;
    my $sth;
    my $query;

    $dsn = "DBI:Pg:$new_conninfo;";
    eval {
        $dbh = DBI->connect($dsn, '', '', {RaiseError => 1});
        $query = "SHOW server_version";
        $sth = $dbh->prepare($query);
        $sth->execute();
        $version = $sth->fetchrow;

        unless (substr($version,0,3) >= 9.4) {
            die "PostgreSQL server version 9.4 or later required to apply changes with ALTER SYSTEM\n";
        }

        foreach $key (keys %g_gucs) {
	    my $set_key;
            my $set_val;
            my $msg1;
            my $msg2;

            $setting++;
            if (exists($g_gucs_obs{$key}) && (substr($version,0,3) > $g_gucs_obs{$key}[0])) {
                if (defined($g_gucs_obs{$key}[1])) {
                    $set_key = $g_gucs_obs{$key}[1];
                    $set_val = eval($g_gucs{$g_gucs_map{$set_key}[0]} . $g_gucs_map{$set_key}[3]);
                    $msg1 = "$g_gucs_obs{$key}[1] (replaces $key after pg $g_gucs_obs{$key}[0])";
                    $msg2 = "$set_val (instead of $key = $g_gucs{$key})\n";
                }
                else {
                    print "$setting) Not setting $key : Setting obsolete after pg $g_gucs_obs{$key}[0] : would have been $key = $g_gucs{$key}\n";
                    next;
                }
            }
            else {
                $set_key = $key;
                $set_val = $g_gucs{$key};
                $msg1 = $set_key;  
                $msg2 = $g_gucs{$key};
            }

            $query = "SELECT CASE vartype WHEN 'string' THEN quote_literal(reset_val) ELSE reset_val END 
                    FROM pg_catalog.pg_settings WHERE lower(name) = lower(?)";
            $sth = $dbh->prepare($query);
            $sth->bind_param(1, $set_key);
            $sth->execute();
            $value = $sth->fetchrow;
            if ($g_debug) {
                print "$setting) KEY: $set_key SVAL: $value VAL: $set_val\n";
            }
            if ($value eq $set_val) {
                print "$setting) Not setting $msg1 : the values are already the same $value = $set_val\n";
            }
            else {
                print "$setting) Setting $msg1 to $set_val : was set to $value\n";
                $query = "ALTER SYSTEM SET " . qtrim($set_key) . " TO ?";
                $sth = $dbh->prepare($query);
                $sth->bind_param(1, qtrim($set_val));
                $sth->execute();
                $change_count++;
            }
        }

        $sth->finish();
    };
    if ($@) {
        print "ERROR: $@\n";
    }
    return $change_count;
}

sub trim {
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

sub qtrim {
    my $string = shift;
    $string =~ s/^('|")+//;
    $string =~ s/('|")+$//;
    return $string;
}

sub currentTimestamp{
    my $timestamp;
    my ($year, $month, $day, $hour, $min, $sec);
    ($year, $month, $day, $hour, $min, $sec) = (localtime(time))[5,4,3,2,1,0];
    $timestamp = sprintf ("%02d/%02d/%04d %02d:%02d:%02d", $day, $month+1, $year+1900, $hour, $min, $sec);
    return $timestamp;
}

sub sizePretty {
    my $size = shift;
    foreach ('B','KB','MB','GB','TB','PB')
    {
        return sprintf("%.2f",$size)." $_" if $size < 1024;
        $size /= 1024;
    }
}
