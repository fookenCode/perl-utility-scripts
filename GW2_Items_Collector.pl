#!/usr/bin/perl -w

# GW2_Items_Collector.pl
# Author: fookenCode
# Description: Make calls against the GW2 API framework to gather information about the in-game Items.
#                     Then store this information in Relational Database for cached usage to limit call volume to services.
# Usage: GW2_Items_Collector.pl  --startPage (optional) --debug (optional)

use strict;
use warnings;

use Data::Dumper;
use DBI;
use Getopt::Long;
use JSON::XS;
use LWP::UserAgent;

my $DEBUG = 0;
my $startPage = 1;

GetOptions(
    "startPage:i" => \$startPage,
    "debug!" => \$DEBUG
);

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->env_proxy;

my $dbh = DBI->connect("dbi:mysql:database=<database>;host=<host>;port=<port>", "<user>", "<pw>") 
    or die "Couldn't connect: $DBI::errstr\n";

my $sth = $dbh->prepare("insert into items (itemId, name, description, itemType, level, rarity, ".
                                          "vendorValue, icon, chatLink, itemSubType, armorWeight, miniPetId, ". 
                                          "bagSlotsTotal, itemSellable) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?) on duplicate key update ".
                                          "name = VALUES(name), description = VALUES(description), itemType = VALUES(itemType), ".
                                          "level = VALUES(level), rarity = VALUES(rarity), vendorValue = VALUES(vendorValue), ".
                                          "icon = VALUES(icon), chatLink = VALUES(chatLink), itemSubType = VALUES(itemSubType), ".
                                          "armorWeight = VALUES(armorWeight), miniPetId = VALUES(miniPetId), ".
                                          "bagSlotsTotal = VALUES(bagSlotsTotal), itemSellable = VALUES(itemSellable)");
my $ath = $dbh->prepare("update items set itemSellable = ? where itemId = ?");

my $response = $ua->get("https://api.guildwars2.com/v2/items?page=$startPage&page_size=200");

if ($response->is_success)
{
        print Dumper $response if $DEBUG;
        my $totalPages = $response->{'_headers'}{'x-page-total'};  
        parseResponseForFullEntry($response);
        
        # Loop over the number of pages in the initial response header
        for (my $iter = $startPage+1; $iter < $totalPages; $iter+=1)
        {
            $response = $ua->get("https://api.guildwars2.com/v2/items?page=$iter&page_size=200");
            
            if ($response->{'_headers'}{'x-page-total'} != $totalPages)
            {
                print "[ERROR]: Total number of pages no longer accurate!\n";
                print "Original value: $totalPages.  New Value: " . $response->{'_headers'}{'x-page-total'}."\n";
                # Exit the program to allow for manual restart
                exit 1;
            }
            
            parseResponseForFullEntry($response);
            print "Processed request #$iter of $totalPages.  Sleeping 1 seconds...\n";
            
            # Rudimentary sleep to self-throttle requests
            sleep 1;
            print "Next request in progress.\n" if $DEBUG;
        }
}
$ath->finish();
$sth->finish();
$dbh->disconnect();

sub parseResponseForFullEntry {
    my ($response) = @_;
    
    foreach my $item (@{decode_json($response->{'_content'})})
    {
        $sth->bind_param(1, $item->{'id'});
        $sth->bind_param(2, $item->{'name'});
        $sth->bind_param(3, $item->{'description'});
        $sth->bind_param(4, $item->{'type'});
        $sth->bind_param(5, $item->{'level'});
        $sth->bind_param(6, $item->{'rarity'});
        $sth->bind_param(7, $item->{'vendor_value'});
        $sth->bind_param(8, $item->{'icon'});
        $sth->bind_param(9, $item->{'chat_link'});
        $sth->bind_param(10, $item->{'details'}->{'type'});
        $sth->bind_param(11, $item->{'details'}->{'weight_class'});
        $sth->bind_param(12, $item->{'details'}->{'minipet_id'});
        $sth->bind_param(13, $item->{'details'}->{'size'});
        # Negate the grep value, multiply by 1 to change to Numeric value to store in the column
        $sth->bind_param(14,  (!(grep { "NoSell" eq $_ } @{$item->{'flags'}}) * 1));
        
        $sth->execute();
    }
}

sub parseResponseForSellableFieldEntry {
    my ($response) = @_;
    my $canSell = 1;
    my $filterValue = "NoSell";
    foreach my $item (@{decode_json($response->{'_content'})})
    {
        if (grep { $filterValue eq $_ } @{$item->{'flags'}})
        {
            $canSell = 0;
            $ath->bind_param(1, $canSell);
            $ath->bind_param(2, $item->{'id'});
            $ath->execute();
        }
    }
}