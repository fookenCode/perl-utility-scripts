#!/usr/bin/perl

# GW2_DailyAchievements_Collector.pl
# Author: fookenCode
# Description: Make calls against the GW2 API framework to gather information about Achievements (currently: Today & Tomorrow's Dailies).
#                     Then store this information in Relational Database for cached usage to limit call volume to services.
# Usage: GW2_DailyAchievements_Collector.pl  --debug (optional)

use strict;
use warnings;

use Data::Dumper;
use DateTime;
use DBI;
use Getopt::Long;
use JSON::XS;
use LWP::Simple; 

my $DEBUG = 0;
GetOptions(
    "debug!" => \$DEBUG
);

# CONSTANTS
my $baseURL = 'https://api.guildwars2.com/v2/achievements';
my $defaultAchievementIcon = "https://render.guildwars2.com/file/483E3939D1A7010BDEA2970FB27703CAAD5FBB0F/42684.png";
my $dailyAchievementURL = $baseURL."/daily";
my $dailyTomorrowAchieveURL = $dailyAchievementURL."/tomorrow";
my $queryURL = $baseURL."?ids=";


my $dbh = DBI->connect("dbi:mysql:database=gw2data;host=<host>;port=<port>;", "<user>", "<password>") or die "Couldn't connect.\n";
my $sth = $dbh->prepare("insert into achievements (achievementId, name, description, requirement, minLevel, maxLevel, accessLevel, icon, pvpFlag, expireTime, category) values(?,?,?,?,?,?,?,?,?,?,?) on duplicate key update ".
                                          "name = VALUES(name), description = VALUES(description), requirement = VALUES(requirement), minLevel = VALUES(minLevel), maxLevel = VALUES(maxLevel), accessLevel = VALUES(accessLevel),".
                                          "icon = VALUES(icon), pvpFlag = VALUES(pvpFlag), expireTime = VALUES(expireTime), category = VALUES(category)");
my $ath = $dbh->prepare("insert into rewards (achievementId, rewardId, rewardType, rewardCount) values(?,?,?,?) on duplicate key update rewardId = VALUES(rewardId), rewardType = VALUES(rewardType), rewardCount = VALUES(rewardCount)");


#Create a timestamp used for expiration date of achievements gathered
my $time = time();
my $dt = DateTime->today();
$dt->add(days => 1);
$dt->subtract(seconds =>1);


# ARRAYS - Hold the achievements to query and Ids
my @dailyIds = ();
my %dailyDetails;
my @tommIds = ();
my %tommDetails;

findAchievements($dailyAchievementURL, \@dailyIds, \%dailyDetails);
getAndStoreAchievements($queryURL.join(',', @dailyIds), \%dailyDetails);

findAchievements($dailyTomorrowAchieveURL, \@tommIds, \%tommDetails);
# Adjust date to the correct end date for Tomorrow's achievements
$dt->add(days => 1); 
getAndStoreAchievements($queryURL.join(',', @tommIds), \%tommDetails);

$ath->finish();
$sth->finish();
$dbh->disconnect();


sub getAndStoreAchievements {
    my ($achieveDetailsURL, $moreDetails) = (@_);
    print "[getAndStoreAchievements]: Retrieving Achievements from: ".$achieveDetailsURL."\n";
    my $json = get $achieveDetailsURL;
    die "Couldn't get AchievementDaily details" unless defined $json;

    foreach my $achievement (@{decode_json($json)})
    {
        $sth->bind_param(1, $achievement->{'id'});
        $sth->bind_param(2, $achievement->{'name'});
        $sth->bind_param(3, $achievement->{'description'});
        $sth->bind_param(4, $achievement->{'requirement'});
        $sth->bind_param(5, $moreDetails->{$achievement->{'id'}}->{'min'});
        $sth->bind_param(6, $moreDetails->{$achievement->{'id'}}->{'max'});
        $sth->bind_param(7, $moreDetails->{$achievement->{'id'}}->{'access_level'});
        if (!defined($achievement->{'icon'})) {
            $sth->bind_param(8, $defaultAchievementIcon);
        }
        else {
            $sth->bind_param(8, $achievement->{'icon'});
        }

        my $pvpFlag = 0;
        if (grep  {'Pvp'  eq $_ } @{$achievement->{'flags'}}) {
            $pvpFlag = 1;
        }
        $sth->bind_param(9, $pvpFlag);
        $sth->bind_param(10, $dt->epoch());
        $sth->bind_param(11, $moreDetails->{$achievement->{'id'}}->{'category'});
        $sth->execute();
        
        foreach my $reward (@{$achievement->{'rewards'}}) {
            $ath->bind_param(1, $achievement->{'id'});
            $ath->bind_param(2, $reward->{'id'});
            my $itemType = 0;
            if ($reward->{'type'} eq 'Coin')
            {
                $itemType = 1;
            }
            elsif($reward->{'type'} eq 'Item')
            {
                $itemType = 2;
            }
            elsif($reward->{'type'} eq 'Mastery')
            {
                $itemType = 3;
            }
            $ath->bind_param(3, $itemType);
            $ath->bind_param(4, $reward->{'count'});
            $ath->execute();
        }
    }
}



sub findAchievements {
   my ($url, $dailyIds, $moreDetails) = (@_);
   
   print "[getStoreAchievements]: Initial gathering of Achievements from: ".$url."\n";
   my $response = get $url;
   die "Couldn't get $url" unless defined $response;
   my $achievementJSON = decode_json($response);

   foreach my $key (keys %{$achievementJSON}) {
       print "Root Key: $key\n" if $DEBUG;
       foreach my $achievement (@{%{$achievementJSON}{$key}}) {
            foreach my $chieveKey (keys %{$achievement}) {
                if (ref(\%{$achievement}{$chieveKey}) eq "SCALAR") {
                    print "Key: $chieveKey and Scalar Value: ". %{$achievement}{$chieveKey}."\n" if $DEBUG;
                    if ($chieveKey eq 'id') {
                        push(@$dailyIds, $achievement->{$chieveKey});
                        $moreDetails->{$achievement->{'id'}}->{'category'} = $key;
                    }
                } elsif (ref(%{$achievement}{$chieveKey}) eq "ARRAY") {
                    foreach my $entry (@{%{$achievement}{$chieveKey}}) {
                        print "Key: $chieveKey and Array Entry: $entry\n" if $DEBUG;
                    }
                    if ($chieveKey eq 'required_access') {
                        if (scalar(@{$achievement->{$chieveKey}}) > 1)
                        {
                            $moreDetails->{$achievement->{'id'}}->{'access_level'} = 0;
                        }
                        elsif (grep {'GuildWars2' eq $_ } @{$achievement->{$chieveKey}})
                        {
                            $moreDetails->{$achievement->{'id'}}->{'access_level'} = 1;
                        }
                        else
                        {
                            $moreDetails->{$achievement->{'id'}}->{'access_level'} = 2;
                        }
                    }
                } elsif (ref(%{$achievement}{$chieveKey}) eq "HASH") {
                    foreach my $entry (keys %{%{$achievement}{$chieveKey}}) {
                        print "Key: $entry and Hash Entry: ". %{%{$achievement}{$chieveKey}}{$entry}."\n" if $DEBUG;
                        if ($entry eq 'min')
                        {
                            $moreDetails->{$achievement->{'id'}}->{'min'} = $achievement->{$chieveKey}->{$entry};
                        }
                        elsif($entry eq 'max')
                        {
                            $moreDetails->{$achievement->{'id'}}->{'max'} = $achievement->{$chieveKey}->{$entry};
                        }
                    }
                } else {
                    print "Not Scalar,Array,Hash!\n";
                    print ref(%{$achievement}{$chieveKey}) ."\n" if $DEBUG;
                }
            }
       }
    }
}
