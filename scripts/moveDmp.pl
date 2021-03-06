################################################################################
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

use strict;
use File::Spec::Functions;
use Time::Local;
use File::Basename;

our $TRUE = 1;
our $FALSE = 0;
our $SUCCESS = 1;
our $FAILURE = 0;

my $path;
my $testRoot;
my $spec;
for (my $i = 0; $i < scalar(@ARGV); $i++) {
	my $arg = $ARGV[$i];
	if ($arg =~ /^\-\-compileLogPath=/) {
		($path) = $arg =~ /^\-\-compileLogPath=(.*)/;
	} elsif ($arg =~ /^\-\-testRoot=/) {
		($testRoot) = $arg =~ /^\-\-testRoot=(.*)/;
	} elsif ($arg =~ /^\-\-spec=/) {
		($spec) = $arg =~ /^\-\-spec=(.*)/;
	}
}

if ($path && $testRoot && $spec) {
	my $location = dirname($path);
	open my $Log, '<', "$path";
	my $compileLog = do { local $/; <$Log> };
	moveTDUMPS($compileLog, $location, $spec);
}

sub logMsg {
	my ($second,$minute,$hour,$day,$month,$year,undef,undef,undef) = localtime;
	$month++;
	$year+=1900;
	printf("%04d%02d%02d-%02d:%02d:%02d - ",$year,$month,$day,$hour,$minute,$second);
	my $val = shift;
	# Wipe any trailing \n's
	$val=~ s/\r|\n//g;
	print $val."\n";
}

sub strip {
	my ($str) = @_;
	$str =~ s/^\s+//g;
	$str =~ s/\s+$//g;
	return $str;
}

sub storeFile {
	# get filename and search argument
	my ($filename) = @_;
	my @lines = ();
	# strip out any quotes...
	($filename) =~ s/\"//g;
	# check the file exists
	if (!(-e $filename)) {
		logMsg("SYSTEM ERROR: The system cannot find the file $filename.");
		return [];
	}
	if (!(-r $filename)) {
		logMsg("SYSTEM ERROR: The system does not have read access to the file $filename.");
		return [];
	}
	# open file
	open (FILE, "<$filename");
	# search array
	@lines = <FILE>;
	close FILE;
	return \@lines;
}

sub checkLog {
	my ($dump, $log) = @_;
	my $cmdSucceed = 0;
	my $dumpFound = 1;
	my $cleanFile = 0;
	my $logFile = storeFile($log);
	if (-e $log) {
		$log =~ s/\.log//;
		if (scalar (@{$logFile}) != 0) {
			logMsg("Contents of $log log:");
			foreach my $line (@{$logFile}) {
				($line) = strip($line);
				print ("$line \n");
				if ($line =~ /(file name could not be located)/) {
					$dumpFound = 0;
					logMsg("ERROR: Unable to $log TDUMP named $dump");
				} elsif ($line =~ /(write error|no space left)/) {
					$cleanFile = 1;
					logMsg("ERROR: Machine disk full, unable to $log dump, aborting $log..");
				} elsif ($line =~ /(No such file or directory)/) {
					$cleanFile = 1;
					logMsg("ERROR: Unable to find the directory to place the dump named $dump");
				}
			}
			logMsg("End of $log log \n");
			unlink($logFile);
		} else {
			$log = $log."d";
			$cmdSucceed = 1;
			logMsg("Successfully $log the dump $dump \n");
		}
	} else {
		logMsg("ERROR: $log does not exist \n");
	}
	return ($cmdSucceed, $dumpFound, $cleanFile);
}

sub moveTDUMPS {
	my ($file, $moveLocation, $spec) = @_;
	my @dumplist = ();
	# Use a hash to ensure that each dump is only dealt with once
	my %parsedNames = ();
	if ($spec !~ /zos/) {
		my $moveCMD = "find ".${testRoot}." -name 'core.*.dmp' -exec mv -t ".${moveLocation}." '{}' +";
		qx($moveCMD);
		return;
	}
	
	if ($file) {
		while ($file =~ /IEATDUMP success for DSN='(.*)'/g) {
			$parsedNames{$1} = 1;
		}
		# A partial dump has been created, even though it is a failure, dump still occurred and needs moving
		while ($file =~ /IEATDUMP failure for DSN='(.*)' RC=0x00000004 RSN=0x00000000/g) {
			$parsedNames{$1} = 1;
		}
		# Dump failed due to no space left on the machine, so print out warning message
		while ($file =~ /IEATDUMP failure for DSN='(.*)' RC=0x00000008 RSN=0x00000026/g) {
			logMsg("ERROR: TDUMP failed due to no space left on machine. $1 cannot be found.");
		}
	}
	push(@dumplist, keys(%parsedNames));
	if (!@dumplist) {
		# Nothing to do
		return;
	}
	logMsg("Attempting to retrieve dumps with names: '" . join("', '", @dumplist), "' and move to '$moveLocation'");
	my %movedDumps = ();
	foreach my $dump (@dumplist) {
		my $cmdSucceed;
		my $dumpFound;
		my $cleanFile;
		my $moveLog = "move.log";
		my $deleteLog = "delete.log";
		if ($dump !~ /X&DS/) {
			my $coreDump = "core."."$dump".".dmp";
			my $cmd = "mv \"//'${dump}'\" ". catfile($moveLocation, $coreDump);
			qx($cmd 2>$moveLog);
			($cmdSucceed, $dumpFound, $cleanFile) = checkLog($dump, $moveLog);
			if ($cmdSucceed) {
				logMsg("Found TDUMP named $dump, and renamed it $coreDump located at $moveLocation");
				$movedDumps{$dump} = 1;
			}
			if ($cleanFile) {
				my $cmd = "mv \"//'${dump}'\" /dev/null";
				qx($cmd 2>$deleteLog);
				checkLog($dump,"delete.log");
			}
		} else {
			logMsg("Naming of dump consistent with multiple dumps \n");
			my @parts;
			$dump =~ s/\.X&DS//;
			logMsg("Changed dump name to $dump \n");
			my $coreDump = "core."."$dump".".dmp";
			my $num = qx(tso listcat | grep $dump | wc -l);
			$num =~ s/^\s+|\s+$//g;
			my $numFiles = int($num);
			if ($numFiles == 0) {
				logMsg("ERROR: dump does not exist");
			}
			my $dump01;
			for (my $i=1; $i <= $numFiles; $i++) {
				if (($i >= 1) && ($i < 10)) {
					$dump01 = $dump.".X00".$i;
				} elsif (($i >= 10) && ($i < 100)) { 
					$dump01 = $dump.".X0".$i;
				} else {
					$dump01 = $dump.".X".$i;
				}
				logMsg("Looking for $dump01 \n");
				logMsg("Appending the contents of ${dump01} to $coreDump \n");
				my $cmd = "cat \"//'${dump01}'\" ".">> ". catfile($moveLocation, "$coreDump");
				qx($cmd 2>$moveLog);
				($cmdSucceed, $dumpFound, $cleanFile) = checkLog($dump01,$moveLog);
				if ($cmdSucceed) {
					logMsg("Found TDUMP named $dump01, and appended the contents to $coreDump located at $moveLocation");
					$movedDumps{$dump01} = 1;
				}
				if ($dumpFound) {
					my $cmd = "mv \"//'${dump01}'\" /dev/null";
					qx($cmd 2>$deleteLog);
					checkLog($dump01,"delete.log");
				}
			}
		}
	}
	my @returnList = keys(%movedDumps);
	logMsg("TDUMP Summary:");
	foreach my $line (@returnList) {
		print("$line \n");
	}
	logMsg("End of TDUMP Summary");
	return (@returnList);
}

1;
