#!/usr/bin/perl -w

# s3napback.pl
# Manage cycling, incremental, compressed, encrypted backups on Amazon S3.
#
# Version 1.04
#
# Copyright (c) 2008-2009 David Soergel
# 418 Richmond St., El Cerrito, CA  94530
# dev@davidsoergel.com
#
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#     * Redistributions of source code must retain the above copyright notice,
#       this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the author nor the names of any contributors may
#       be used to endorse or promote products derived from this software
#       without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

use strict;
use warnings;
use Log::Log4perl;
use Date::Format;
use File::stat;
use Getopt::Std;
use Config::ApacheFormat;
use File::Spec::Functions qw(rel2abs);
use File::Basename;

my $diffdir;
my $tempdir;
my $bucket;
my $recipient;
my $encrypt;
my $delete_from_s3;
my $send_to_s3;

my %isAlreadyDoneToday = ();
my %opt;

my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
$year += 1900;
$mon  += 1;
my $datestring = time2str( "%Y-%m-%d", time );
my $curPath = dirname( rel2abs($0) ) . "/";

###### Setup logging

my $conf_file = 's3napback.logconfig';
Log::Log4perl->init($conf_file);
my $logger = Log::Log4perl::get_logger();

sub main() {

###### Print the header

    $logger->info("Starting s3napback");

###### Process command-line Arguments + Options

    getopts( 'c:t', \%opt ) || die usage();

    #if($opt{h}) {
    #	usage();
    #	exit 2;
    #}

    #my $debug = 0;

    if ( $opt{t} ) {
        $logger->warn("TEST MODE ONLY, NO REAL ACTIONS WILL BE TAKEN");
    }

###### Find config files

    my @configs;

    # Hmm, does Getopt::Std modify @ARGV to contain only what it didn't parse, or are we here looking at the whole thing?
    # (doesn't really matter in practice)

    for (@ARGV) {
        if ( -f "/etc/s3napback/$_.conf" ) {
            push @configs, "/etc/s3napback/$_.conf";
        }
        elsif ( -f "/etc/s3napback/$_" ) {
            push @configs, "/etc/s3napback/$_";
        }
    }

    unshift @configs, $opt{c} if $opt{c};
    @configs = '' unless @configs;

###### Parse config files

    for my $configfile (@configs) {
        my $mainConfig = Config::ApacheFormat->new(
            duplicate_directives => 'combine',
            inheritance_support  => 0
        );

        $mainConfig->read($configfile);

        #print "config=" . $mainConfig->dump() . "\n";

        $diffdir = $mainConfig->get("DiffDir");
        $diffdir || die "DiffDir must be defined.";

        # insure that $diffdir ends with a slash
        if ( !( $diffdir =~ /\/$/ ) ) {
            $diffdir = $diffdir . "/";
        }

        $tempdir = $mainConfig->get("TempDir");
        if ( defined $tempdir ) {
            #  $tempdir || die "TempDir must be defined.";

            # insure that $tempdir ends with a slash
            if ( !( $tempdir =~ /\/$/ ) ) {
                $tempdir = $tempdir . "/";
            }
        }

        $bucket = $mainConfig->get("Bucket");
        $bucket || die "Bucket must be defined.";

        my $keyring = $mainConfig->get("GpgKeyring");
        if ($keyring) {
            $keyring = "--keyring $keyring";
        }
        else {
            $keyring = "";
        }

        my $recipient = $mainConfig->get("GpgRecipient");

        # $recipient || die "GpgRecipient must be defined.";
        # Empty recipient OK; in that case we just won't use GPG.

        my $s3keyfile = $mainConfig->get("S3Keyfile");
        $s3keyfile || die "S3Keyfile must be defined.";

        my $chunksize = $mainConfig->get("ChunkSize");
        $chunksize || die "ChunkSize must be defined.";

        #my $notifyemail = $mainConfig->get("NotifyEmail");
        #my $logfile = $mainConfig->get("LogFile");
        #my $loglevel = $mainConfig->get("LogLevel");

        ###### Check gpg key availability

        my $checkgpg = `gpg --batch $keyring --list-public-keys`;
        if ( defined $recipient && !( $checkgpg =~ /$recipient/ ) ) {
            $logger->logdie("GPG recipient $recipient not found in $checkgpg");

            #die "Requested GPG public key not found: $recipient";
        }

        ###### Setup commands (this is the crux of the matter)

        if ( defined $recipient ) {
            $encrypt = "| gpg --batch $keyring -r $recipient -e";
        }

        $send_to_s3     = "java -jar ${curPath}js3tream.jar --debug -z $chunksize -n -f -v -K $s3keyfile -i -b";    # -Xmx128M
        $delete_from_s3 = "java -jar ${curPath}js3tream.jar -v -K $s3keyfile -d -b";

        ###### Check what has already been done

        my $list_s3_bucket = "java -jar ${curPath}js3tream.jar -v -K $s3keyfile -l -b $bucket 2>&1";

        $logger->info("Getting current contents of bucket $bucket modified on $datestring...");
        my @bucketlist = `$list_s3_bucket`;

        $logger->debug( join "\n", @bucketlist );

        my @alreadyDoneToday = grep /$datestring/, @bucketlist;    ######### THIS DID NOT WORK BEFORE, TEST AGAIN #########

        # 2008-04-10 04:07:50 - dev.davidsoergel.com.backup1:MySQL/all-0 - 153.38k in 1 data blocks
        @alreadyDoneToday = map { s/^.* - (.*?) - .*$/$1/; chomp; $_ } @alreadyDoneToday;

        $logger->info("Buckets already done today:");

        #map { print; print "\n"; } @alreadyDoneToday;
        for (@alreadyDoneToday) { $logger->info($_); $isAlreadyDoneToday{$_} = 1; }

        ###### Perform the requested operations

        processBlock($mainConfig);

        for my $cycle ( $mainConfig->get("Cycle") ) {
            my $block = $mainConfig->block($cycle);
            processBlock($block);
        }

    }

}

sub processBlock() {
    my ($config) = @_;

    for my $name ( $config->get("Directory") ) {

        #print "Directory $name\n";

        my $block = $config;
        if ( ref($name) eq 'ARRAY' ) {
            $logger->info( $name->[0] . " => " . $name->[1] );
            $block = $config->block($name);
            $name  = $name->[1];
        }

        my @excludes = $block->get("Exclude");

        backupDirectory( $name, cyclespec($block), @excludes );
    }

    for my $name ( $config->get("Subversion") ) {

        #print "Subversion $name\n";

        my $block = $config;
        if ( ref($name) eq 'ARRAY' ) {
            $logger->info( $name->[0] . " => " . $name->[1] );
            $block = $config->block($name);
            $name  = $name->[1];
        }

        backupSubversion( $name, cyclespec($block) );
    }

    for my $name ( $config->get("SubversionDir") ) {
        my $block = $config;
        if ( ref($name) eq 'ARRAY' ) {
            $logger->info( $name->[0] . " => " . $name->[1] );
            $block = $config->block($name);
            $name  = $name->[1];
        }

        backupSubversionDir( $name, cyclespec($block) );
    }

    for my $name ( $config->get("MySQL") ) {
        my $block = $config;
        if ( ref($name) eq 'ARRAY' ) {
            $logger->info( $name->[0] . " => " . $name->[1] );
            $block = $config->block($name);
            $name  = $name->[1];
        }

        backupMysql( $name, cyclespec($block) );
    }

}

sub backupDirectory {
    my ( $name, @cyclespec, @excludes ) = @_;
    my ( $frequency, $phase, $diffs, $fulls, $usetemp ) = @cyclespec;

    if ( ( $yday + $phase ) % $frequency != 0 ) {
        $logger->warn("Skipping $name");
        return;
    }

    my $difffile = $name . ".diff";
    $difffile =~ s/\//_/g;
    $difffile = $diffdir . $difffile;

    my $sb = stat($difffile);
    if ( defined $sb ) {
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $diffyday, $isdst ) = localtime( $sb->mtime );

        if ( $diffyday == ( $yday + $phase ) ) {
            $logger->warn("Skipping $name; diff was already performed today");
            return;
        }
    }

    my $cycles = $fulls * ( $diffs + 1 );
    my $cyclenum = ( ( $yday + $phase ) / $frequency ) % $cycles;

    my $type = "DIFF";

    if ( $cyclenum % ( $diffs + 1 ) == 0 ) {
        $type = "FULL";
        unlink $difffile;
    }

    my $excludes = "";

    for my $exclude (@excludes) {
        $excludes .= " --exclude $exclude";
    }

    my $datasource     = "tar $excludes -g $difffile -C / -czp $name";
    my $bucketfullpath = "$bucket:$name-$cyclenum-$type";

    $logger->info("Directory $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp );
}

sub backupMysql {
    my ( $name, @cyclespec ) = @_;

    my ( $frequency, $phase, $diffs, $fulls, $usetemp ) = @cyclespec;

    # note $diffs is ignored

    if ( ( $yday + $phase ) % $frequency != 0 ) {
        $logger->warn("Skipping $name");
        return;
    }

    my $cycles = $fulls;
    my $cyclenum = ( ( $yday + $phase ) / $frequency ) % $cycles;

    my $socket    = "";
    my $socketopt = "";
    if ( $name =~ /(.*):(.*)/ ) {
        $socket    = $1;
        $socketopt = "--socket $1";
        $name      = $2;
    }
    if ( $name eq "all" ) { $name = "--all-databases"; }
    my $datasource = "mysqldump --opt $socketopt $name | gzip";

    if ($socket) {
        $name = "$socket/$name";
    }

    my $bucketfullpath = "$bucket:MySQL/$name-$cyclenum";
    $logger->info("MySQL $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp );
}

# old version made only full backups, no diffs
# sub backupSubversion
#	{
#	my ($name, $frequency, $phase, $fulls) = @_;
#
#	if(($yday + $phase) % $frequency != 0)
#		{
#		print "Skipping $name\n";
#		return;
#		}
#
#	my $cycles = $fulls;
#	my $cyclenum = (($yday + $phase) / $frequency) % $cycles;
#
#	my $datasource = "svnadmin -q dump $name | gzip";
#	my $bucketfullpath = "$bucket:$name-$cyclenum";
#
#	print "Subversion $name -> $bucketfullpath\n";
#	sendToS3($datasource, $bucketfullpath);
#	}

sub backupSubversionDir {
    my ( $name, @cyclespec ) = @_;
    my ( $frequency, $phase, $diffs, $fulls, $usetemp ) = @cyclespec;

    # this will be rechecked for each individual directory, but we may as well abort now if it's the wrong day
    if ( ( $yday + $phase ) % $frequency != 0 ) {
        $logger->warn("Skipping $name");
        return;
    }

    # inspired by https://popov-cs.grid.cf.ac.uk/subversion/WeSC/scripts/svn_backup

    opendir( DIR, $name );
    my @subdirs = readdir(DIR);
    closedir(DIR);

    foreach my $subdir (@subdirs) {
        $logger->debug(`svnadmin verify $name/$subdir 2>&1 1>/dev/null`);
        if ( $? == 0 ) {
            backupSubversion( "$name/$subdir", @cyclespec );
        }
    }
}

#
# Inspired by from http://le-gall.net/pierrick/blog/index.php/2007/04/17/98-subversion-incremental-backup
# Adapted to s3napback by Kevin Ross - metova.com
#
sub backupSubversion {
    my ( $name, @cyclespec ) = @_;

    my ( $frequency, $phase, $diffs, $fulls, $usetemp ) = @cyclespec;

    if ( ( $yday + $phase ) % $frequency != 0 ) {
        $logger->warn("Skipping $name");
        return;
    }

    my $difffile = $name . ".diff";
    $difffile =~ s/\//_/g;
    $difffile = $diffdir . $difffile;

    # initialize the last saved revision as -1, that way on the first pass it is simply incremented to 0 (the first revision).
    my $lastSavedRevision = -1;

    # check the time on any existing diff file to see if this was already done today.
    my $sb = stat($difffile);
    if ( defined $sb ) {
        my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $diffyday, $isdst ) = localtime( $sb->mtime );

        if ( $diffyday == ( $yday + $phase ) ) {
            $logger->warn("Skipping $name -- was already backed up today");
            return;
        }

        # The diff file exists and we need to run, so read the last saved revision from the file
        open( LAST_SAVED_REVISION, '<', $difffile );
        $lastSavedRevision = <LAST_SAVED_REVISION>;
        chomp $lastSavedRevision;
        close(LAST_SAVED_REVISION);
    }

    my $cycles = $fulls * ( $diffs + 1 );
    my $cyclenum = ( ( $yday + $phase ) / $frequency ) % $cycles;

    my $type = "DIFF";

    if ( $cyclenum % ( $diffs + 1 ) == 0 || $lastSavedRevision < 0 ) {
        $type = "FULL";

        # remove the diff file, we want to do a full backup.
        unlink $difffile;
        $lastSavedRevision = -1;
    }

    # get informed of the current last revision (head)
    my $headRevision = `svnlook youngest $name`;
    chomp $headRevision;

    $logger->debug("Last revision of $name: $headRevision");

    if ( $type eq "DIFF" && $lastSavedRevision == $headRevision ) {

        # of course, if the head is not younger than the last saved revision it's useless to go on backing up.
        $logger->info("$name has no new revisions since last backup; skipping");
        return;
    }

    # if the last saved is 1000 and the head is 1023, we want the backup from 1001 to 1023
    my $fromRevision = $lastSavedRevision + 1;
    my $toRevision   = $headRevision;

    my $datasource     = "svnadmin dump -q -r$fromRevision:$toRevision --incremental $name | gzip";
    my $bucketfullpath = "$bucket:$name-$cyclenum-$type";

    $logger->info("Subversion $name -> $bucketfullpath");
    sendToS3( $datasource, $bucketfullpath, $usetemp );

    # Save last revision to the diff file so we know where to pick up later.
    if ( !$opt{t} ) {
        open( LAST_SAVED_REVISION, '>', $difffile );
        print LAST_SAVED_REVISION $toRevision, "\n";
        close(LAST_SAVED_REVISION);
    }
}

sub sendToS3 {
    my ( $datasource, $bucketfullpath, $shouldUseTempFile ) = @_;

    if ( $isAlreadyDoneToday{$bucketfullpath} && !$opt{f} ) {
        $logger->warn("Skipping $bucketfullpath -- already done today");
        return;
    }

    # setup in case this is a temp file scenario
    my $tempfile = $bucketfullpath . ".temp";
    $tempfile =~ s/\//_/g;
    $tempfile = $tempdir . $tempfile;

    if ( $opt{t} ) {

        $logger->info("$delete_from_s3 $bucketfullpath");

        # print out the statements for test mode.
        if ( $shouldUseTempFile == 1 ) {

            # stream the data to a temp file first, then to jS3tream
            $logger->info("Using temp file to buffer before streaming[ $tempfile ]...");
            $logger->info("$datasource $encrypt > $tempfile");
            $logger->info("$send_to_s3 $bucketfullpath <  $tempfile");
            $logger->info("rm $tempfile");
        }
        else {

            # stream the data
            $logger->info("$datasource $encrypt | $send_to_s3 $bucketfullpath");
        }

        return;
    }

    # delete the bucket if it exists
    $logger->debug(`$delete_from_s3 $bucketfullpath`);

    if ( $? != 0 ) {
        $logger->error("Could not delete old backup: $!");
    }

    if ( $shouldUseTempFile == 1 ) {
        $tempdir || $logger->logdie(
            "TempDir must be defined in order to UseTempFile
."
        );

        # stream the data to a temp file first, then to jS3tream
        $logger->info("Using temp file to buffer before streaming [ $tempfile ]...");
        $logger->debug(`$datasource $encrypt > $tempfile`);

        if ( $? != 0 ) {
            $logger->error("Could stream to temporary file: $!");
        }
        else {
            $logger->debug(`$send_to_s3 $bucketfullpath <  $tempfile`);
        }

        deleteOnError();

        # delete the remnants of the temp file if there was one.
        $logger->info("Deleting temp file [ $tempfile ].");
        unlink $tempfile;

    }
    else {

        # stream the data
        $logger->debug(`$datasource $encrypt | $send_to_s3 $bucketfullpath`);
        deleteOnError();
    }

}

sub deleteOnError {
    my ($bucketfullpath) = @_;

    if ( $? != 0 ) {
        $logger->error("Backup to $bucketfullpath failed: $!");
        $logger->error("Deleting any partial backup");

        # delete the bucket if it exists
        $logger->debug(`$delete_from_s3 $bucketfullpath`);

        if ( $? != 0 ) {
            $logger->error("Could not delete partial backup: $!");
        }
    }

}

sub cyclespec {
    my ($block) = @_;

    my $frequency = $block->get("Frequency");
    my $phase     = $block->get("Phase");
    my $diffs     = $block->get("Diffs");
    my $fulls     = $block->get("Fulls");
    my $usetemp   = $block->get("UseTempFile");

    if ( !defined $frequency ) { $frequency = 1; }
    if ( !defined $phase )     { $phase     = 0; }
    if ( !defined $diffs )     { $diffs     = 6; }
    if ( !defined $fulls )     { $fulls     = 4; }

    return ( $frequency, $phase, $diffs, $fulls, $usetemp );
}

main();
