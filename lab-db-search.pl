#!/usr/bin/perl
use strict;
use Getopt::Long;
use DBI;
my ($help,$racknum,$model,$models,$total,$info,$verbose,$labid);
GetOptions('help|?' => \$help,'rack=i' => \$racknum, 'model=s' => \$model,'models' => \$models,'labid=i' => \$labid, 'verbose'=>\$verbose, 'total'=> \$total, 'info=s' => \$info);
&help() unless ( $racknum || $model || $models || $total || $info || $labid);
my %hash;
my $dbh = DBI->connect('DBI:mysql:<dbname>:hostname=<hostname>','<username>', '<password>') || die "Could not connect to database: $DBI::errstr";
&info if $info;
&models if $models;
&model($model) if $model;
&total if $total;
&racknum if $racknum;
&labid if ($labid && !$racknum); # no need to call for &labid if &racknum is called.
sub info()
{	
        my $sth1 = $dbh->prepare("select * from labs where name = \"$info\";");
        $sth1->execute  or die "SQL Error: $DBI::errstr\n";
        my ($name,$lab,$rack,$floor,$model,$description)=$sth1->fetchrow();
	if (! defined ($name)) {
		print "$info wasn't found\n";
		exit 1;
	} else {
		print "Name: $name\n";
		print "Lab: $lab\n";
		print "Rack: $rack\n";
		print "Floor: $floor\n";
		print "Model: $model\n";
		print "Description: $description\n";	
	}
}
sub labid()
{
	$labid="Lab".$labid;
	my $sth = $dbh->prepare("select name from labs where lab=\"$labid\";");
	$sth->execute  or die "SQL Error: $DBI::errstr\n";
	my $count=0;
	my @hosts;
	while (my $name= $sth->fetchrow()) {
		$count++;
		push @hosts,$name;
	}
	if ( $count == 0 )	{
		print "The specified rack doesn't exist or isn't documented.\n";
		exit 1;
	} else {
		print "The following hosts reside in $labid:\n";
		for (sort @hosts) {
			print "$_\n";
		}
		print "Total: $count hosts\n";
	}
}
sub racknum()
{
	if (!$labid) {
		die "Oops. Must specify the lab id (--labid 3 or 4).\n"
	}
	$labid="Lab".$labid;
	if ($racknum <10) {
		$racknum="Rack0".$racknum;
	} else {
		$racknum="Rack".$racknum;
	}
	my $sth = $dbh->prepare("select name from labs where rack=\"$racknum\" and lab=\"$labid\";");
	$sth->execute  or die "SQL Error: $DBI::errstr\n";
	my $count=0;
	my @hosts;
	while (my $name= $sth->fetchrow()) {
		$count++;
		push @hosts,$name;
	}
	if ( $count == 0 )	{
		print "The specified rack doesn't exist or isn't documented.\n";
		exit 1;
	} else {
		print "The following hosts reside in $racknum:\n";
		for (sort @hosts) {
			print "$_\n";
		}
		print "Total: $count hosts\n";
	}
}
sub total()
{
	my $count_total=0;
	my $count_unique=0;
	#$answer=$dbh->selectrow_hashref("select count(*) from lab;");
	my $sth1 = $dbh->prepare("select count(*) from labs;");
	$sth1->execute  or die "SQL Error: $DBI::errstr\n";
	$count_total=$sth1->fetchrow();
	my $sth2 = $dbh->prepare("select count(distinct model) from labs;");
	$sth2->execute  or die "SQL Error: $DBI::errstr\n";
	$count_unique=$sth2->fetchrow();
	print "There are $count_total devices in total in the LAB and $count_unique different types of devices\n";
}
sub model() 
{
	my $sth;
	my $totalcount=0;
	if ($verbose) {
		$sth = $dbh->prepare("select name,model from labs where model like \"%$model%\" order by model;");
	} else {
		$sth = $dbh->prepare("select name,model,count(name) from labs where model like \"%$model%\" group by model;");
	} 
        $sth->execute  or die "SQL Error: $DBI::errstr\n";
	my ($name,$localmodel,$count);
	my %hash;
	if ($verbose) {
		while (($name,$localmodel)= $sth->fetchrow()) {
			$hash{$localmodel}{'name'}=$hash{$localmodel}{'name'}."\t$name\n";	
			$hash{$localmodel}{'count'}++;
			$totalcount++;
		}

	} else {
	        while (($name,$localmodel,$count)=$sth->fetchrow()) {
			$totalcount+=$count;
			print "There are $count units of $localmodel\n";
		}
        }
	if ($verbose) {
	       for $localmodel(keys %hash) {
                        print "There are $hash{$localmodel}{'count'} units of $localmodel:\n";
			print "$hash{$localmodel}{'name'}";	
                }
        }
	print "Total number of $model units: $totalcount\n";
}
sub models() 
{
	my $sth;
	my $totalcount=0;
	if ($verbose) {
		$sth = $dbh->prepare("select name,model from labs order by model;");
	} else {
		$sth = $dbh->prepare("select name,model,count(name) from labs group by model;");
	} 
        $sth->execute  or die "SQL Error: $DBI::errstr\n";
	my ($name,$model,$count);
	my %hash;
	if ($verbose) {
		while (($name,$model)= $sth->fetchrow()) {
			$hash{$model}{'name'}=$hash{$model}{'name'}."\t$name\n";	
			$hash{$model}{'count'}++;	
		}

	} else {
	        while (($name,$model,$count)=$sth->fetchrow()) {
			print "There are $count units of $model\n";
			$totalcount++;
		}
        }
	if ($verbose) {
	       for $model(keys %hash) {
			$totalcount++;
                        print "There are $hash{$model}{'count'} units of $model:\n";
			print "$hash{$model}{'name'}";	
                }
        }
	print "Total number of models: $totalcount\n";
}
sub help() 
{
	print "Usage: $0 <option>\n";
	print "This script searches through the documented Racks and counts the existing machines.\n";
	print "Possible options:\n";
	print "--help print this menu (default)\n";
	print "--labid lists the hosts in specific lab\n";
	print "--rack <rack number> list the hosts in specific rack. Requires the --labid argument\n";
	print "--model <model name> [-v] print counts of specific model\n";
	print "--models [-v] print counts of all models\n";
	print "--total print the total number of devices/models\n";
	print "--info <machine name> show all the available info for the device\n";
	exit;
}
