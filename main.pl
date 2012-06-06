#!/usr/bin/perl
#
# $Id: main.pl,v 1.1 2012/12/28 12:19:00 web privacy measurement Exp $ #
#
# Script to parse HTTP Headers into D3 json by Rob van Eijk (rob@blaeu.com)
#
# Copyright MPL 1.1/GPL 2.0/LGPL 2.1 - see bottom of this file
#
# -------------------------------------------------------------------------
# Usage: main.pl <file>
#
# Run the LiveHTTPheaders Add On in Firefox. Visit websites and save the
# captured headers to a <file>. 
# Alternatively, you can use Fiddler as a web proxy, select all records
# and export captured headers to a <>file>.
# This PERL script will convert the <file> into a JSON that can be used
# with the D3 library to display tracking in a colored force-diagram.
# -------------------------------------------------------------------------

use strict;
use warnings;
use DBI;
use Data::Dumper;
use Switch;
use URI;

# read the specified file
die "Usage: $^X $0 liveHTTP-headers\n" unless @ARGV;
my $file      = $ARGV[0];

# -------------------------------------------------------------------------
print "start processing '$file'\n";
# -------------------------------------------------------------------------
my $start = time;
my $ouputfile = $file . ".json";
my $logfile   = $file . ".log";
my $dumpfile =  $file . ".gz";
$dumpfile =~ s/ /\\ /g;
my $log       = "start processing $file\r\n";

my $http_headers = readFile($file);

# -------------------------------------------------------------------------
print "[1/8] opening sqlite database\n";
# -------------------------------------------------------------------------
my $dbh = DBI->connect( "dbi:SQLite:connections.sqlite",
	"", "", { RaiseError => 1, AutoCommit => 1 } );

eval {
	local $dbh->{PrintError} = 0;
	$dbh->do("DROP TABLE trackers");
	$dbh->do("DROP TABLE domains");
	$dbh->do("DROP TABLE names");
	$dbh->do("DROP TABLE distinct_groups");
	$dbh->do("DROP TABLE distinct_domains");
	$dbh->do("DROP TABLE distinct_names");
};

# (re)create table(s)
$dbh->do("CREATE TABLE trackers (tracker, groups)")
  || die "Could not create table TRACKERS";
$dbh->do("CREATE TABLE distinct_groups (tracker PRIMARY KEY, groups)")
  || die "Could not create table GROUPS";
$dbh->do("CREATE TABLE domains ( source_domain, target_domain )")
  || die "Could not create table DOMAINS";
$dbh->do(
"CREATE TABLE distinct_domains (id INTEGER PRIMARY KEY, source_domain, target_domain, source_node INTEGER, target_node INTEGER, tot_value INTEGER)"
) || die "Could not create table DISTINCT_DOMAINS";
$dbh->do("CREATE TABLE names (id INTEGER PRIMARY KEY, domain )")
  || die "Could not create table NAMES";
$dbh->do(
"CREATE TABLE distinct_names (id INTEGER PRIMARY KEY, domain, groups INTEGER)"
) || die "Could not create table DISTINCT_NAMES";

# -------------------------------------------------------------------------
print "[1/8] pre-loading preliminary websites...\n";
# -------------------------------------------------------------------------
my $group = 0;
foreach my $websites (
#	qw(demorgen.be standaard.be tijd.be gva.be hbvl.be hln.be nieuwsblad.be lecho.be dhnet.be lalibre.be lameuse.be lesoir.be nieuwsblad.be grenzecho.net rnews.be lavenir.net tbx.be)
#   qw(pzc.nl tctubantia.nl adformatie.nl ad.nl beleggersbelangen.nl depers.nl groene.nl volkskrant.nl telegraaf.nl elsevier.mobi fd.nl parool.nl nd.nl nieuwsbank.nl nrc.nl refdag.nl spitsnieuws.nl trouw.nl vi.nl vn.nl agd.nl barneveldsekrant.nl blikopnieuws.nl bndestem.nl bd.nl limburger.nl dg.nl gooieneemlander.nl destentor.nl ed.nl frieschdagblad.nl ijmuidercourant.nl leidschdagblad.nl meppelercourant.nl metronieuws.nl noordhollandsdagblad.nl nrcnext.nl)
    qw(vol.at vienna.at tt.com pressetext.com kleinezeitung.at grazer.at woche.at wirtschaftsblatt.at wienerzeitung.at salzburg.com oe24.at kurier.at krone.at kathpress.at hrvatskenovine.at heute.at diepresse.com derstandard.at twoday.net austriantimes.at)
  )
{
	$dbh->do("INSERT INTO trackers VALUES ('$websites', '$group')");
}

# -------------------------------------------------------------------------
print "[2/8] pre-loading confirmed tracking domains...\n";
# -------------------------------------------------------------------------
$group = 1;
$file = "trackers.json";
my $priv_choice = readFile($file);
my @track_headers = split /,/, $priv_choice;
foreach my $tracker (@track_headers) {
	if ( $tracker =~ m/domain/ ) {
		$tracker =~ s/\r\n    \"domain\": \"//g;
		$tracker =~ s/\"//g;
		$tracker =~ s/co\.uk/co_uk/g;
		my @subdomains = split /\./, $tracker;

		switch ( scalar @subdomains ) {
			case 2 { $tracker = $subdomains[0] . "." . $subdomains[1] }
			case 3 { $tracker = $subdomains[1] . "." . $subdomains[2] }
			case 4 {
				$tracker = $subdomains[2] . "." . $subdomains[3];
			}
		}
		$tracker =~ s/co_uk/co\.uk/g;
		$dbh->do("INSERT INTO trackers VALUES ('$tracker', '$group')");
	}
}
undef $priv_choice;
undef @track_headers;

# -------------------------------------------------------------------------
print "[3/8] parsing HTTP headers...\n";
# -------------------------------------------------------------------------
my @live_headers = split /\r\n/, $http_headers;
my $target;
my $domainsource;
my $domaintarget;
my $sameframe = 0;
my $cnt_headers;

foreach (@live_headers) {
	$target = $_;

	if ( $target =~ m/Host:/ ) {
		$target =~ s/Host: //g;
		$target =~ s/co\.uk/co_uk/g;
		my @subdomains = split /\./, $target;

		my $test_ipadres = $subdomains[0] . ".";

		switch ( scalar @subdomains ) {
			case 2 { $domaintarget = $subdomains[0] . "." . $subdomains[1] }
			case 3 { $domaintarget = $subdomains[1] . "." . $subdomains[2] }
			case 4 {
				if ( $test_ipadres =~ m/\b\d{1,3}\./ ) {

					$domaintarget =
					  $subdomains[0] . "." . $subdomains[1] . ".x.x";

				}
				else {

					$domaintarget = $subdomains[2] . "." . $subdomains[3];
				}

			}

		}
		$sameframe = 0;
	}

	if ( $target =~ m/Referer:/ ) {
		$target =~ s/Referer: //g;

		my $url    = URI->new("$target");
		my $domain = $url->host;

		$domain =~ s/co\.uk/co_uk/g;
		my @subdomains = split /\./, $domain;

		my $test_ipadres = $subdomains[0] . ".";

		switch ( scalar @subdomains ) {
			case 2 { $domainsource = $subdomains[0] . "." . $subdomains[1] }
			case 3 { $domainsource = $subdomains[1] . "." . $subdomains[2] }
			case 4 {
				if ( $test_ipadres =~ m/\b\d{1,3}\./ ) {

					$domainsource =
					  $subdomains[0] . "." . $subdomains[1] . ".x.x";

				}
				else {

					$domainsource = $subdomains[2] . "." . $subdomains[3];
				}
			}
		}
		$sameframe = 1;
	}

	if ( $target =~ m/-------------/ ) {
		$cnt_headers++;
		switch ($sameframe) {
			case 0 {
				$domaintarget =~ s/co_uk/co\.uk/g;
				$dbh->do(
"INSERT INTO domains VALUES ('$domaintarget', '$domaintarget')"
				);
			}
			case 1 {
				$domainsource =~ s/co_uk/co\.uk/g;
				$domaintarget =~ s/co_uk/co\.uk/g;
				$dbh->do(
"INSERT INTO domains VALUES ('$domainsource', '$domaintarget')"
				);
			}
		}
		$sameframe = 0;
	}
}
undef $http_headers;
undef @live_headers;

# distinct domains
my $sth = $dbh->prepare(
"select distinct source_domain, target_domain from domains order by domains.target_domain"
);
$sth->execute;
my $cnt_domains;
while ( ( my $source, my $target ) = $sth->fetchrow_array() ) {
	$dbh->do(
"INSERT INTO distinct_domains VALUES (NULL, '$target', '$source', NULL, NULL, NULL)"
	);
	$dbh->do("INSERT INTO names VALUES (NULL, '$source')");
	$dbh->do("INSERT INTO names VALUES (NULL, '$target')");
	$cnt_domains++;
}
$sth->finish();

# distinct names
$sth = $dbh->prepare("select distinct domain from names order by names.domain");
$sth->execute;
my $cnt_names;
while ( ( my $domain ) = $sth->fetchrow_array() ) {
	$dbh->do("INSERT INTO distinct_names VALUES (NULL, '$domain', NULL)");
	$cnt_names++;
}
$sth->finish();

# distinct trackers
$sth = $dbh->prepare(
	"select distinct tracker, groups from trackers order by trackers.tracker");
$sth->execute;
while ( ( my $tracker, my $groups ) = $sth->fetchrow_array() ) {
	$dbh->do("INSERT INTO distinct_groups VALUES ('$tracker', '$groups')");
}
$sth->finish();

# -------------------------------------------------------------------------
print "[4/8] linking nodes...\n";
# -------------------------------------------------------------------------
# lookup distinct_names.groups in tabel distinct_groups
my @correct_group;
my $id;
$sth = $dbh->prepare("select * from distinct_names");
$sth->execute;
while ( ( $id, my $domain, my $groups1 ) = $sth->fetchrow_array() ) {
	my $sti = $dbh->prepare(
		"select groups from distinct_groups where tracker='$domain'");
	$sti->execute;
	if ( ( my $groups2 ) = $sti->fetchrow_array() ) {
		$correct_group[$id] = $groups2;
	}
	else {
		$correct_group[$id] = '2';    # other non confirmed trackers
	}
	$sti->finish();
}
$sth->finish();
for ( $id = 1 ; $id <= $cnt_names ; $id++ ) {
	$sth = $dbh->prepare(
		"UPDATE distinct_names SET groups='$correct_group[$id]' WHERE id='$id'"
	);
	$sth->execute;
	$sth->finish();
}

# lookup distinct_domains.source_node in tabel distinct_names
my @correct_source;
$sth = $dbh->prepare("select id, source_domain from distinct_domains");
$sth->execute;
while ( ( $id, my $source_domain ) = $sth->fetchrow_array() ) {
	my $sti = $dbh->prepare(
		"select id from distinct_names where domain='$source_domain'");
	$sti->execute;
	$correct_source[$id] = $sti->fetchrow_array();
	$correct_source[$id]--;
	$sti->finish();
}
$sth->finish();
for ( $id = 1 ; $id <= $cnt_domains ; $id++ ) {
	$sth = $dbh->prepare(
"UPDATE distinct_domains SET source_node='$correct_source[$id]' WHERE id='$id'"
	);
	$sth->execute;
	$sth->finish();
}

# lookup distinct_domains.target_node in tabel distinct_names
my @correct_target;
$sth = $dbh->prepare("select id, target_domain from distinct_domains");
$sth->execute;
while ( ( $id, my $target_domain ) = $sth->fetchrow_array() ) {
	my $sti = $dbh->prepare(
		"select id from distinct_names where domain='$target_domain'");
	$sti->execute;
	$correct_target[$id] = $sti->fetchrow_array();
	$correct_target[$id]--;
	$sti->finish();
}
$sth->finish();
for ( $id = 1 ; $id <= $cnt_domains ; $id++ ) {
	$sth = $dbh->prepare(
"UPDATE distinct_domains SET target_node='$correct_target[$id]' WHERE id='$id'"
	);
	$sth->execute;
	$sth->finish();
}

# lookup value
my @correct_value;
$sth = $dbh->prepare("select id, source_domain from distinct_domains");
$sth->execute;
while ( ( $id, my $source_domain ) = $sth->fetchrow_array() ) {
	my $sti = $dbh->prepare(
		"select groups from distinct_names where domain='$source_domain'");
	$sti->execute;
	$correct_value[$id] = $sti->fetchrow_array();
	$sti->finish();
}
$sth->finish();
for ( $id = 1 ; $id <= $cnt_domains ; $id++ ) {
	my $calculation = 1 + $correct_value[$id] * 3;
	$sth = $dbh->prepare(
		"UPDATE distinct_domains SET tot_value='$calculation' WHERE id='$id'");
	$sth->execute;
	$sth->finish();
}

# -------------------------------------------------------------------------
print "[5/8] writing $ouputfile\n";
# -------------------------------------------------------------------------
# create nodes
my $json = "{\"nodes\":[";

$sth = $dbh->prepare("select * from distinct_names order by distinct_names.id");
$sth->execute;
while ( ( $id, my $tracker, my $grouping ) = $sth->fetchrow_array() ) {
	if ( $id == 1 ) {
		$json = $json . "{\"name\":\"$tracker\",\"group\":$grouping}";
	}
	else {
		$json = $json . ",{\"name\":\"$tracker\",\"group\":$grouping}";
	}
}
$json = $json . "]";
$sth->finish();

# create links
$json = $json . ",\"links\":[";
my $first_entry = 1;

$sth = $dbh->prepare(
	"select id, source_node, target_node, tot_value from distinct_domains");
$sth->execute;

while ( ( $id, my $source, my $target, my $tot_value ) =
	$sth->fetchrow_array() )
{
	if ( $first_entry == 1 ) {
		$json = $json
		  . "{\"source\":$source,\"target\":$target,\"value\":$tot_value}";
		$first_entry--;
	}
	else {
		$json = $json
		  . ",{\"source\":$source,\"target\":$target,\"value\":$tot_value}";
	}
}
$json = $json . "]}";
$sth->finish();
writeFile( $ouputfile, $json );

# query confirmed trackers
my $cnt_tracker;
$sth = $dbh->prepare(
	"select COUNT(groups) from distinct_names WHERE distinct_names.groups='1'");
$sth->execute;
$cnt_tracker = $sth->fetchrow_array();
$sth->finish();

# -------------------------------------------------------------------------
print "[6/8] closing sqlite database\n";
# -------------------------------------------------------------------------
$dbh->disconnect();

my $proc = time - $start;

if ($proc) {
	$log = $log . "\r\n$cnt_headers headers\r\n";
	$log = $log . "$cnt_names nodes\r\n";
	$log = $log . "$cnt_domains links\r\n";
	$log = $log . "$cnt_tracker confirmed trackers\r\n\r\n";
	$log = $log . "job completed succesfully in $proc seconds\r\n\r\n";
}

print "[7/8] writing log file\n";
writeFile( $logfile, $log );

print "[8/8] archiving sqlite tables...Done!\r\n\r\n";
exec("echo '.dump' | sqlite3 connections.sqlite | gzip -c >$dumpfile") || die "Could not dump connections.sqlite to file '$file'";

exit 0;

# -------------------------------------------------------------------------

sub readFile {
	my $file = shift;

	open( local *FILE, "<", $file ) || die "Could not read file '$file'";
	binmode(FILE);
	local $/;
	my $result = <FILE>;
	close(FILE);

	return $result;
}

sub writeFile {
	my ( $file, $contents ) = @_;

	open( local *FILE, ">", $file ) || die "Could not write file '$file'";
	binmode(FILE);
	print FILE $contents;
	close(FILE);
}

# -------------------------------------------------------------------------
# Version: MPL 1.1/GPL 2.0/LGPL 2.1
#
# The contents of this file are subject to the Mozilla Public License Version
# 1.1 (the "License"); you may not use this file except in compliance with
# the License. You may obtain a copy of the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
# for the specific language governing rights and limitations under the
# License.
#
# The Initial Developer of the Original Code is Rob van Eijk.
#
# Portions created by the Initial Developer are Copyright (C) 2011
# the Initial Developer. All Rights Reserved.
#
# Contributor(s): -
#
# Alternatively, the contents of this file may be used under the terms of
# either the GNU General Public License Version 2 or later (the "GPL"), or
# the GNU Lesser General Public License Version 2.1 or later (the "LGPL"),
# in which case the provisions of the GPL or the LGPL are applicable instead
# of those above. If you wish to allow use of your version of this file only
# under the terms of either the GPL or the LGPL, and not to allow others to
# use your version of this file under the terms of the MPL, indicate your
# decision by deleting the provisions above and replace them with the notice
# and other provisions required by the GPL or the LGPL. If you do not delete
# the provisions above, a recipient may use your version of this file under
# the terms of any one of the MPL, the GPL or the LGPL.
# -------------------------------------------------------------------------

