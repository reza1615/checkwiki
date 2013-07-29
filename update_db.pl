#! /usr/bin/env perl

##########################################################################
#
# FILE:   update_db.pl
# USAGE:  update_db.pl --database <databasename> --host <host>
#                      --password <password> --user <username>
#
# DESCRIPTION:  Updates the cw_overview and cw_overview_errors database
#               tables for Checkwiki.  Tables contain a list of current
#               errors found and how many have been fixed (done).
#               Tables are used by update_html.pl to for webpages.
#
#               cw_overview_errors contains data for most webpages.
#               cw_overview contains data for main index.html page.
#
# AUTHOR:  Stefan Kühn
# VERSION: 2013-06-30
# LICENSE: GPL
#
##########################################################################

use strict;
use warnings;

use DBI;
use Getopt::Long
  qw(GetOptionsFromString :config bundling no_auto_abbrev no_ignore_case);

our $dbh;
our @projects;

our $time_start_script = time();
our $time_start;

my ( $DbName, $DbServer, $DbUsername, $DbPassword );

my @Options = (
    'database|d=s' => \$DbName,
    'host|h=s'     => \$DbServer,
    'password=s'   => \$DbPassword,
    'user|u=s'     => \$DbUsername
);

GetOptions(
    'c=s' => sub {
        my $f = IO::File->new( $_[1], '<:encoding(UTF-8)' )
          or die( "Can't open " . $_[1] . "\n" );
        local ($/);
        my $s = <$f>;
        $f->close();
        my ( $Success, $RemainingArgs ) = GetOptionsFromString( $s, @Options );
        die unless ( $Success && !@$RemainingArgs );
    }
);

##########################################################################
## MAIN PROGRAM
##########################################################################

open_db();
get_projects();

cw_overview_errors_insert_new_errors();
cw_overview_errors_update_errors();
cw_overview_errors_update_done();
cw_overview_errors_update_error_number();

cw_overview_insert_new_projects();
cw_overview_update_done();
cw_overview_update_error_number();
cw_overview_update_last_update();
cw_overview_update_last_dump();

#cw_overview_update_last_change();

close_db();
output_duration_script();

##########################################################################
## OPEN DATABASE
##########################################################################

sub open_db {

    # Database configuration.
    #    my $DbName = 'p50380g50450__checkwiki_p';
    #    my $DbServer;
    #    my $DbUsername = 'p50380g50450';
    #    my $DbPassword = 'zahgetumataefeex';

    $dbh = DBI->connect(
        'DBI:mysql:'
          . $DbName
          . ( defined($DbServer) ? ':host=' . $DbServer : '' ),
        $DbUsername,
        $DbPassword,
        {
            RaiseError => 1,
            AutoCommit => 1,
            mysql_enable_utf8 => 1
        }
    ) or die( "Could not connect to database: " . DBI::errstr() . "\n" );

    return ();
}

###########################################################################
## CLOSE DATABASE
###########################################################################

sub close_db {
    $dbh->disconnect();

    return ();
}

###########################################################################
## GET PROJECT NAMES FROM DATABASE (ie enwiki, dewiki)
###########################################################################

sub get_projects {

    print "Load projects from db\n";
    my $result = q();
    my $sth = $dbh->prepare('SELECT project FROM cw_project ORDER BY project;')
      || die "Can not prepare statement: $DBI::errstr\n";
    $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";

    my $project_counter = 0;
    while ( my $arrayref = $sth->fetchrow_arrayref() ) {

        foreach (@$arrayref) {
            $result = $_;
        }

        #print $result . "\n";
        push( @projects, $result );
        $project_counter++;
    }

    #print $project_counter . "projects\n";

    return ();
}

###########################################################################
## INSERT ANY NEW ERRORS INTO cw_overview_errors
###########################################################################

sub cw_overview_errors_insert_new_errors {
    $time_start = time();
    print "Insert all new errors into cw_overview_errors\n";

    foreach (@projects) {
        my $project = $_;

        my $sql_text =
"INSERT INTO cw_overview_errors (project, id, name, name_trans, prio, errors, done)
        (SELECT a.project, a.id, a.name, a.name_trans, a.prio, null, null
        FROM cw_error_desc a
        LEFT OUTER JOIN cw_overview_errors b
        ON (a.id = b.id and a.project=b.project)
        WHERE b.project is null 
        AND b.id IS NULL
        AND a.project = '" . $project . "');";

        #print $sql_text . "\n\n\n";
        my $sth = $dbh->prepare($sql_text)
          || die "Can not prepare statement: $DBI::errstr\n";
        $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";
    }

    output_duration();

    return ();
}

###########################################################################
## UPDATE ERROR DESCRIPTION AND PRIORITY (DOESN'T CHANGE OFTEN)
###########################################################################

sub cw_overview_errors_update_errors {
    $time_start = time();

    print "Update the error_headline and error_headline_translation\n";

    foreach (@projects) {
        my $project = $_;

        #print "\t\t" . $project . "\n";
        my $sql_text = "update cw_overview_errors, (
        SELECT a.project, a.prio, a.id , a.name, a.text, a.name_trans, a.text_trans 
        FROM cw_error_desc a
        WHERE project =  '" . $project . "'
        ) basis
        SET 
        cw_overview_errors.name       = basis.name,
        cw_overview_errors.name_trans = basis.name_trans,
        cw_overview_errors.prio       = basis.prio
        WHERE cw_overview_errors.project = basis.project
        AND cw_overview_errors.id = basis.id
        AND cw_overview_errors.project =  '" . $project . "';
        ";

        #print $sql_text . "\n\n\n";
        my $sth = $dbh->prepare($sql_text)
          || die "Can not prepare statement: $DBI::errstr\n";
        $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";
    }

    output_duration();

    return;
}

###########################################################################
## UPDATE THE NUMBER OF ARTICLES THAT HAVE BEEN DONE
###########################################################################

sub cw_overview_errors_update_done {

    $time_start = time();
    print "Group and count the done articles in cw_error -> update cw_overview_error\n";

    foreach (@projects) {
        my $project = $_;

        my $sql_text = "UPDATE cw_overview_errors, (
        SELECT a.project, a.id , b.done FROM cw_error_desc a
        LEFT OUTER JOIN (
        SELECT COUNT(*) done , error id , project
        FROM cw_error WHERE ok = 1 AND project =  '" . $project . "' 
        GROUP BY project, error
        ) b
        ON a.project = b.project AND a.project =  '" . $project . "'
        AND a.id = b.id
        ) basis
        SET cw_overview_errors.done = basis.done
        WHERE cw_overview_errors.project = basis.project
        AND cw_overview_errors.project =  '" . $project . "'
        AND cw_overview_errors.id = basis.id;";

        my $sth = $dbh->prepare($sql_text)
          || die "Can not prepare statement: $DBI::errstr\n";
        $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";
    }

    output_duration();

    return ();
}

###########################################################################
## UPDATE THE NUMBER OF ERRORS CURRENTLY IN ARTICLES
###########################################################################

sub cw_overview_errors_update_error_number {

    $time_start = time();
    print "Group and count the errors in cw_error -> update cw_overview_error\n";

    foreach (@projects) {
        my $project = $_;

        my $sql_text = "UPDATE cw_overview_errors, (
        SELECT a.project, a.id, b.errors errors  
        FROM cw_error_desc a
        LEFT OUTER JOIN (
        SELECT COUNT( *) errors, error id , project
        FROM cw_error 
        WHERE ok = 0
        AND project =  '" . $project . "'
        GROUP BY project, error
        ) b
        ON a.project = b.project
        AND a.project =  '" . $project . "'
        AND a.id = b.id
        ) basis
        SET cw_overview_errors.errors = basis.errors
        WHERE cw_overview_errors.project = basis.project
        AND cw_overview_errors.project =  '" . $project . "'
        AND cw_overview_errors.id = basis.id;";

        #print $sql_text . "\n\n\n";
        my $sth = $dbh->prepare($sql_text)
          || die "Can not prepare statement: $DBI::errstr\n";
        $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";
    }

    output_duration();

    return ();
}

###########################################################################
## INSERT ANY NEW PROJECTS THAT MAY HAVE BEEN ADDED
###########################################################################

sub cw_overview_insert_new_projects {
    $time_start = time();
    print "Insert new_projects\n";

    my $sql_text =
"INSERT INTO cw_overview (id, project, lang, errors, done, last_dump, last_update, project_page, translation_page)
    (SELECT a.id, a.project, a.lang, null errors, null done, a.last_dump, null last_update, a.wikipage, a.translation_page 
    FROM cw_project a
    LEFT OUTER JOIN cw_overview b
	ON (a.id = b.id)
	WHERE b.project is NULL);";

    my $sth = $dbh->prepare($sql_text)
      || die "Can not prepare statement: $DBI::errstr\n";
    $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";

    output_duration();

    return ();
}

###########################################################################
## UPDATE THE NUMBER OF ERRORS CURRENTLY IN ARTICLES
###########################################################################

sub cw_overview_update_done {
    $time_start = time();
    print "Sum done article in cw_overview_errors --> update cw_overview\n";

    my $sql_text = "UPDATE cw_overview, (
    SELECT IFNULL(sum(done),0) done, project FROM cw_overview_errors GROUP BY project
    ) basis
    SET cw_overview.done = basis.done
    WHERE cw_overview.project = basis.project;";

    #print $sql_text . "\n\n\n";
    my $sth = $dbh->prepare($sql_text)
      || die "Can not prepare statement: $DBI::errstr\n";
    $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";

    output_duration();

    return ();
}

###########################################################################
## UPDATE THE NUMBER OF ERRORS CURRENTLY IN ARTICLES
###########################################################################

sub cw_overview_update_error_number {
    $time_start = time();
    print "Sum errors in cw_overview_errors --> update cw_overview\n";

    my $sql_text = "update cw_overview, (
    SELECT IFNULL(sum(errors),0) errors, project FROM cw_overview_errors GROUP BY project
    ) basis
    SET cw_overview.errors = basis.errors
    WHERE cw_overview.project = basis.project;";

    #print $sql_text . "\n\n\n";
    my $sth = $dbh->prepare($sql_text)
      || die "Can not prepare statement: $DBI::errstr\n";
    $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";

    output_duration();

    return ();
}

###########################################################################
## UPDATE THE TIME THIS PROGRAM LAST RUN
###########################################################################

sub cw_overview_update_last_update {
    $time_start = time();
    print "Update last_update\n";
    foreach (@projects) {
        my $project = $_;

        #print "\t\t" . $project . "\n";
        my $sql_text = "-- update last_update
        UPDATE cw_overview, (
        SELECT a.project, b.found found 
        FROM cw_project a
        LEFT OUTER JOIN (
        SELECT max(found) found, project 
        FROM cw_error 
        WHERE project =  '" . $project . "'
        GROUP BY project
        ) b
        ON a.project = b.project
        WHERE a.project =  '" . $project . "'
        ) basis
        SET cw_overview.last_update = basis.found
        WHERE cw_overview.project = basis.project";

        #print $sql_text . "\n\n\n";
        my $sth = $dbh->prepare($sql_text)
          || die "Can not prepare statement: $DBI::errstr\n";
        $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";
    }

    output_duration();

    return ();
}

###########################################################################
## UPDATE THE LAST TIME A DUMP RAN FOR A PARTICULAR PROJECT
###########################################################################

sub cw_overview_update_last_dump {
    $time_start = time();
    print "Update last_dump\n";

    my $sql_text = "-- UPDATE last_dump
    UPDATE cw_overview, (
    SELECT a.project, a.last_dump FROM cw_project a
    ) basis
    SET cw_overview.last_dump = basis.last_dump
    WHERE cw_overview.project = basis.project;";

    #print $sql_text . "\n\n\n";
    my $sth = $dbh->prepare($sql_text)
      || die "Can not prepare statement: $DBI::errstr\n";
    $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";

    output_duration();

    return ();
}

###########################################################################
##
###########################################################################

sub cw_overview_update_last_change {
    print "Update change\n";
    $time_start = time();

    foreach (@projects) {
        my $project = $_;

        #print "\t\t" . $project . "\n";
        my $sql_text = "-- UPATE last_dump
        UPDATE cw_overview, (
        SELECT a.project project, c.errors last, b.errors one, a.errors, a.errors-b.errors diff1, a.errors-c.errors diff7
        FROM (
        SELECT project, IFNULL(errors,0) errors FROM cw_statistic_all 
        WHERE DATEDIFF(now(),daytime) = 0
        AND project =  '" . $project . "'
        ) a JOIN 
        (
        SELECT project, IFNULL(errors,0) errors 
        FROM cw_statistic_all 
        WHERE DATEDIFF(now(),daytime) = 1
        AND project =  '" . $project . "'
        ) b
        ON (a.project = b.project)
        JOIN 
        (SELECT project, ifnull(errors,0) errors FROM cw_statistic_all 
        WHERE DATEDIFF(now(),daytime) = 7
        AND project =  '" . $project . "'
        ) c
        ON (a.project = c.project)
        ) basis
        SET cw_overview.diff_1 = basis.diff1, 
        cw_overview.diff_7 = basis.diff7
        WHERE cw_overview.project = basis.project
        AND cw_overview.project =  '" . $project . "';";

        #print $sql_text . "\n\n\n";
        my $sth = $dbh->prepare($sql_text)
          || die "Can not prepare statement: $DBI::errstr\n";
        $sth->execute or die "Cannot execute: " . $sth->errstr . "\n";
    }

    output_duration();

    return ();
}

###########################################################################
## SUBROUTINES TO DETERMINE HOW LONG A SUB OR THE PROGRAM RAN
###########################################################################

sub output_duration {
    my $time_end         = time();
    my $duration         = $time_end - $time_start;
    my $duration_minutes = int( $duration / 60 );
    my $duration_secounds =
      int( ( ( int( 100 * ( $duration / 60 ) ) / 100 ) - $duration_minutes ) *
          60 );
    print "Duration:\t"
      . $duration_minutes
      . ' minutes '
      . $duration_secounds
      . ' secounds' . "\n\n";

    return ();
}

sub output_duration_script {
    my $time_end         = time();
    my $duration         = $time_end - $time_start_script;
    my $duration_minutes = int( $duration / 60 );
    my $duration_secounds =
      int( ( ( int( 100 * ( $duration / 60 ) ) / 100 ) - $duration_minutes ) *
          60 );
    print "Duration of script:\t"
      . $duration_minutes
      . ' minutes '
      . $duration_secounds
      . ' secounds' . "\n";

    return ();
}
