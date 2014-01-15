#!/usr/bin/perl
# The first argument is either insert - for populating the database, or update for updating the values
# The second (optional) argument should be a file/directory name with data to populate/update the database with. If this argument isn't provided - all the available data in all racks is pushed/updated.
use strict;
use File::Find;
use File::Basename;
use DBI;                                                                                                        
if ($ARGV[0] ne "update" && $ARGV[0] ne "insert" && $ARGV[0] ne "remove") {
	die "The argument should be either insert or update or remove\n";
}
if (!$ARGV[1] && $ARGV[0] ne "insert") {
	die "The argument to \"$ARGV[0]\" is missing.\n";
}
# initialiaze the database + one table per example below:
# create database engops;
# use engops;
#create table labs (name char(30) not null primary key, lab varchar(6) not null, rack varchar(10) not null, floor varchar(50) not null, model varchar(50) not null, description varchar(1500));  
#grant all on engops.labs to '<username>'@'<hostname>' identified by '<password>';
#grant select on engops.labs to '<rouser>'@'<hostname>' identified by '<password>';
my $dbh = DBI->connect('DBI:mysql:<dbname>:hostname=<hostname>', '<username>', '<password>') || die "Could not connect to database: $DBI::errstr";                                      
my ($sql,$sth);

if ($ARGV[0] eq "remove" ) {
	print "Removing $ARGV[1]...\n";
	$sql = "delete from labs where name like \"$ARGV[1]\"";
	$sth = $dbh->prepare($sql);
	$sth->execute  or die "SQL Error: $DBI::errstr\n";
	exit;
}
	
my @racks;
my %hash;
my @path=("/home/$ENV{USER}/Documents/Labs/Lab4/","/home/$ENV{USER}/Documents/Labs/Lab3/" ); # Rack\d\d directories should be under that path
for my $path (@path) {
	if (-f $ARGV[1] or -d $ARGV[1]) { #create/update a subset of the database table
		find (\&rackid,$ARGV[1]);
	} else {
		my $max_rack;
		if ($path=~/Lab3/) {
			$max_rack=3;
		} 
		else {
			$max_rack=11;
		}
		for (1..$max_rack) { # currently have 11 racks on the 4th floor and 3 on the 3rd floor- check all exist
			$_="0".$_ if $_ < 10;
			$_=$path."Rack".$_;
			die "No such directory \"$_\". Please check the script.\n" unless -d $_;
			push @racks, $_;
		}
		for (@racks) {
			find (\&rackid,$_);
		}	
	}
}
for my $name(keys %hash) {
	next if $hash{$name}{'name'} eq '';
	if ($ARGV[0] eq "insert"){
		#INSERT INTO engops (rackid,name,model,description) VALUES (8,"buri01","HP SL390s","This machine is used by the integration team"); 
		$sql = "INSERT INTO labs (name,lab,rack,floor,model,description) VALUES (\"$hash{$name}{'name'}\", \"$hash{$name}{'lab'}\", \"$hash{$name}{'rack'}\", \"$hash{$name}{'floor'}\", \"$hash{$name}{'model'}\", \'$hash{$name}{'description'}\');";
	} elsif ($ARGV[0] eq "update") {
		#update lab SET rackid='2O' where name='description'; 
		$sql = "UPDATE engops.labs SET name = \"$hash{$name}{'name'}\", lab = \"$hash{$name}{'lab'}\",floor = \"$hash{$name}{'floor'}\", model = \"$hash{$name}{'model'}\", description = \'$hash{$name}{'description'}\' where name like \"$hash{$name}{'name'}\";";
	} else {
		die "You didn't provide a correct insert/update/remove argument.\n";
	}
	
	$sth = $dbh->prepare($sql);
	$sth->execute  or die "SQL Error: $DBI::errstr\n";
}
# this subroutine gets all the details from a file and stores them in a hash
sub rackid()
{
		# the name and the location are taken from the filename and the path respectively
		my $name=basename($File::Find::name);             
		my $rack=dirname($File::Find::name);             
                my @path;                                            
		if ($rack =~ /Lab3/) {
			$hash{$name}{'lab'}="Lab3";	
		}	
		elsif ($rack =~ /Lab4/) {
			$hash{$name}{'lab'}="Lab4";
		}
		else {
			$hash{$name}{'lab'}="Not identified";
		}
                if ($rack !~ /Rack\d{2}$/) { # to deal with blade centers/systems
                        $rack=dirname($File::Find::name);                       
                        @path= split /\//, $rack;                               
                        pop @path;      #remove the last directory from the path    
                        $rack=join "/",@path;                                   
		}
                $rack=basename($rack);                              
		next if ($rack !~ /Rack\d{2}$/); # get rid of current directory './'
		my ($model,$floor,$description)=undef;
		if ( -f $_) {
			open CURRENT_FILE, $_ or die "Couldn't open a file:$!\n";
			# get the model, the floor and the description from the file
			while (<CURRENT_FILE>) {
				if (/^Model:(.*)/) {
					$hash{$name}{'model'}=$1;
				}
				elsif (/^Floor:\s{1}(.*)/) {
					$hash{$name}{'floor'}=$1; 
				}
				else {
					next if /^$/; # get rid of empty lines
					$description=$description.$_;
				}
			}
			$hash{$name}{'name'}=$name;
			$hash{$name}{'rack'}=$rack;
			$hash{$name}{'floor'}="No floor marks on the rack" unless defined($hash{$name}{'floor'});
			if (defined $description) {
				chomp $description;
				$hash{$name}{'description'}=$description;
			}
			close CURRENT_FILE;
		}
}
