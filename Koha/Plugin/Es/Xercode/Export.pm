package Koha::Plugin::Es::Xercode::Export;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use utf8;
use C4::Context;
use C4::Members;
use C4::Auth;

use Koha::Authority::Types;
use Koha::Biblioitems;
use Koha::CsvProfiles;
use Koha::Database;
use Koha::Exporter::Record;
use Koha::ItemTypes;
use Koha::Libraries;
use Koha::DateUtils;

use MARC::Record;
use JavaScript::Minifier qw(minify);
use File::Copy;
use File::Temp;
use File::Basename;
use Pod::Usage;
use Text::CSV::Encoded;
use List::MoreUtils qw(uniq);
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use IO::Tee;
use JSON;

our $tee = IO::Tee->new( \*STDOUT );

use constant ANYONE => 2;

BEGIN {
    use Config;
    use C4::Context;

    my $pluginsdir  = C4::Context->config('pluginsdir');
}

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'Koha Plugin Export',
    author          => 'Xercode Media Software S.L.',
    description     => 'Koha Plugin Export',
    date_authored   => '2020-08-02',
    date_updated    => '2020-08-13',
    minimum_version => '18.11',
    maximum_version => undef,
    version         => $VERSION,
};

our $dbh = C4::Context->dbh();


sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    
    my $userid = C4::Context->userenv ? C4::Context->userenv->{number} : undef;
    
    my $template = $self->get_template( { file => 'tool.tt' } );
    
    if ( $self->retrieve_data('enabled') ) {
        $template->param(enabled => 1);
    }

    my $store_directory = $self->retrieve_data('store_directory');
    $store_directory =~ s/^\s+|\s+$//g;
    my $configok = 1;
    if ($store_directory eq ""){
        $template->param(store_directory_notset => 1);
        $configok = 0;
    }else{
        if ( not -w $store_directory) {
            $template->param(store_directory_notwritable => 1);
            $configok = 0;
        }
    }

    $template->param(configok => $configok);
    
    if ( $self->retrieve_data('enabled') ) {
        $template->param(enabled => 1);
    }

    my $dbh = C4::Context->dbh;

    my $jobid = $cgi->param("id");
    my $op = $cgi->param("op") || "";
    my $table_jobs = $self->get_qualified_table_name('jobs');
    
    if ($jobid){
        my $sth = $dbh->prepare("SELECT * FROM $table_jobs WHERE id = ?");
        $sth->execute($jobid);
        my $row = $sth->fetchrow_hashref;

        my $table_log = $self->get_qualified_table_name('log');
        
        if ($row){
            if ($op eq "cancel"){
                if (C4::Context->IsSuperLibrarian() || ($row->{borrowernumber} == $userid)){
                    if ($row->{"status"} eq "new"){
                        $dbh->do("UPDATE $table_jobs SET status = ? WHERE id = ?", undef, ('cancelled', $jobid));

                        $dbh->do(
                            qq{
                                INSERT INTO $table_log (`borrowernumber`, `job_id`, `action` ) VALUES ( ?, ?, ? );
                            }
                            , undef, ( $userid, $jobid, 'cancel' )
                        );
                        
                        print $cgi->redirect("/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AEs%3A%3AXercode%3A%3AExport&method=tool");
                    }
                }
            }
            if ($op eq "resume"){
                if (C4::Context->IsSuperLibrarian() || ($row->{borrowernumber} == $userid)){
                    if ($row->{"status"} eq "cancelled"){
                        $dbh->do("UPDATE $table_jobs SET status = ? WHERE id = ?", undef, ('new', $jobid));

                        $dbh->do(
                            qq{
                                INSERT INTO $table_log (`borrowernumber`, `job_id`, `action` ) VALUES ( ?, ?, ? );
                            }
                            , undef, ( $userid, $jobid, 'resume' )
                        );
                        
                        print $cgi->redirect("/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AEs%3A%3AXercode%3A%3AExport&method=tool");
                    }
                }
            }
            if ($op eq "remove"){
                if (C4::Context->IsSuperLibrarian()){
                    if ($row->{"status"} eq "new" || $row->{"status"} eq "cancelled" || $row->{"status"} eq "error" || $row->{"status"} eq "finished"){
                        $store_directory .= "/" unless ($store_directory =~ /\/$/);
                        if (-e $store_directory.$row->{"systemfilename"}){
                            unlink $store_directory.$row->{"systemfilename"};
                        }
                        if (-e $store_directory.$row->{"systemfilename_codification"}){
                            unlink $store_directory.$row->{"systemfilename_codification"};
                        }
                        my $sth = $dbh->prepare("DELETE FROM $table_jobs WHERE ID = ?");

                        $dbh->do(
                            qq{
                                INSERT INTO $table_log (`borrowernumber`, `job_id`, `action`, `information` ) VALUES ( ?, ?, ?, ? );
                            }
                            , undef, ( $userid, $jobid, 'remove', to_json($row) )
                        );
                        
                        $sth->execute($jobid);
                    }
                }
                print $cgi->redirect("/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AEs%3A%3AXercode%3A%3AExport&method=tool");
            }
            if ($op eq "view"){
                $row->{'branch'} =~ s/,/, /g;
                $template->param(job => $row);
                $template->param(jobid => $jobid);
            }
            if ($op eq "download"){
                $store_directory .= "/" unless ($store_directory =~ /\/$/);
                if (-e $store_directory.$row->{"systemfilename"}){
                    my $type = 'application/zip';
                    my $file_fh;
                    my $content;
                    binmode(STDOUT);
                    open $file_fh, '<', $store_directory.$row->{"systemfilename"};
                    $content .= $_ while <$file_fh>;
                    print $cgi->header(
                        -type => $type,
                        -attachment=> $row->{"filename"}.".zip"
                    );
                    print $content;
                    exit;
                }
            }
            if ($op eq "download_report"){
                $store_directory .= "/" unless ($store_directory =~ /\/$/);
                if (-e $store_directory.$row->{"systemfilename_codification"}){
                    my $type = 'file/csv';
                    my $file_fh;
                    my $content;
                    binmode(STDOUT);
                    open $file_fh, '<', $store_directory.$row->{"systemfilename_codification"};
                    $content .= $_ while <$file_fh>;
                    print $cgi->header(
                        -type => $type,
                        -attachment=> $row->{"systemfilename_codification"}
                    );
                    print $content;
                    exit;
                }
            }
        }else{
            print $cgi->redirect("/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AEs%3A%3AXercode%3A%3AExport&method=tool");
        }
        
    }else{
        my $sth = $dbh->prepare("SELECT * FROM $table_jobs");
        $sth->execute();

        my @jobs;
        while ( my $row = $sth->fetchrow_hashref ) {
            push @jobs, $row;
        }
        $template->param(jobs => \@jobs);
    }
    
    print $cgi->header(
        {
            -type     => 'text/html',
            -charset  => 'UTF-8',
            -encoding => "UTF-8"
        }
    );
    
    print $template->output();
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    
    if ( $cgi->param('save') ) {
        my $enabled = $cgi->param('enabled') ? 1 : 0;
        my $database_internal_use = $cgi->param('database_internal_use') ? 1 : 0;
        $self->store_data(
            {
                enabled         => $enabled,
                store_directory => $cgi->param('store_directory'),
                clean_chars     => $cgi->param('clean_chars'),
            }
        );
        $self->go_home();
    }
    else {
        my $template = $self->get_template( { file => 'configure.tt' } );

        $template->param(
            enabled               => $self->retrieve_data('enabled'),
            store_directory       => $self->retrieve_data('store_directory'),
            clean_chars           => $self->retrieve_data('clean_chars'),
        );
        
        print $cgi->header(
            {
                -type     => 'text/html',
                -charset  => 'UTF-8',
                -encoding => "UTF-8"
            }
        );
        print $template->output();
    }
}

sub install() {
    my ( $self, $args ) = @_;
    
    my $dbh = C4::Context->dbh;

    my $table_log = $self->get_qualified_table_name('log');
    $dbh->do(
        qq{
            CREATE TABLE `$table_log` (
              `id` int(11) NOT NULL AUTO_INCREMENT,
              `borrowernumber` int(11) NOT NULL,
              `date_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
              `job_id` tinyint(4) NOT NULL,
              `action` varchar(10),
              `information` text DEFAULT NULL,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        }
    );

    my $table_jobs = $self->get_qualified_table_name('jobs');
    $dbh->do(
        qq{
            CREATE TABLE `$table_jobs` (
              `id` int(11) NOT NULL AUTO_INCREMENT,
              `borrowernumber` int(11) NOT NULL,
              `mailto` varchar(255),
              `record_type` varchar(20) NOT NULL,
              `authtype` varchar(20),
              `branch` TEXT,
              `itemtype` varchar(255),
              `start_datecreated` date default NULL,
              `end_datecreated` date default NULL,
              `start_datemodified` datetime default NULL,
              `end_datemodified` datetime default NULL,
              `start_accession` date default NULL,
              `end_accession` date default NULL,
              `start_callnumber` varchar(250),
              `end_callnumber` varchar(250),
              `id_list_file` TEXT,
              `starting_id` int(11) default NULL,
              `ending_id` int(11) default NULL,
              `export_remove_fields` TEXT,
              `dont_export_item` tinyint(1),
              `strip_items_not_from_libraries` tinyint(1),
              `excludesuppressedbiblios` tinyint(1),
              `output_format` varchar(20) NOT NULL,
              `csv_profile_id` int(11) NULL,
			  `filename` varchar(50),
			  `systemfilename` varchar(50),
              `systemfilename_codification` varchar(100),
			  `status` varchar(32) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
			  `information` text DEFAULT NULL,
              `enqueued_on` datetime DEFAULT NULL,
              `started_on` datetime DEFAULT NULL,
              `ended_on` datetime DEFAULT NULL,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        }
    );
    
    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    my $table_log = $self->get_qualified_table_name('log');
    C4::Context->dbh->do("DROP TABLE $table_log");
    my $table_jobs = $self->get_qualified_table_name('jobs');
    C4::Context->dbh->do("DROP TABLE $table_jobs");
    
    return 1;
}

############################################
#                                          #
#              PLUGIN METHODS              #
############################################

sub status {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};
    
    my $status = ($self->retrieve_data('enabled'))?1:0;

    my $store_directory = $self->retrieve_data('store_directory');
    $store_directory =~ s/^\s+|\s+$//g;
    
    if ($store_directory eq ""){
        $status = 0;
    }else{
        if ( not -w $store_directory) {
            $status = 0;
        }
    }
    
    print $cgi->header( -type => 'application/json', -charset => 'utf-8' );
    print to_json({'status' => \$status});
}

sub createjob {
    my ($self, $args) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool_new.tt' } );
    
    if ( $self->retrieve_data('enabled') ) {
        $template->param(enabled => 1);
    }

    my $store_directory = $self->retrieve_data('store_directory');
    $store_directory =~ s/^\s+|\s+$//g;
    my $configok = 1;
    if ($store_directory eq ""){
        $template->param(store_directory_notset => 1);
        $configok = 0;
    }else{
        if ( not -w $store_directory) {
            $template->param(store_directory_notwritable => 1);
            $configok = 0;
        }
    }

    $template->param(configok => $configok);

    if ( $self->retrieve_data('enabled') && $configok) {
        my $userid = C4::Context->userenv ? C4::Context->userenv->{number} : undef;
        my $dbh = C4::Context->dbh;

        my $table_jobs = $self->get_qualified_table_name('jobs');

        # Branches
        my @branch = $cgi->multi_param("branch");
        my $branches = join(',', @branch);

        # Export items
        my $dont_export_items = 0;
        if ($cgi->param("dont_export_item") eq "on"){
            $dont_export_items = 1;
        }

        # Between IDs
        my $starting_id = 0;
        my $ending_id = 0;
        if ($cgi->param("record_type") eq "bibs"){
            $starting_id = $cgi->param("StartingBiblionumber");
            $ending_id = $cgi->param("EndingBiblionumber");
        }else{
            $starting_id = $cgi->param("starting_authid");
            $ending_id = $cgi->param("ending_authid");
        }

        # Mail
        my $mailto = $cgi->param("mailto");
        if ($mailto eq ""){
            $mailto = C4::Members::GetNoticeEmailAddress($userid);
        }

        # Upload dir
        my $upload_dir        = C4::Context::temporary_directory;
        my $filename = $cgi->param("id_list_file");
        my $upload_filehandle = $cgi->upload("id_list_file");
        open( UPLOADFILE, '>', "$upload_dir/$filename" ) or warn "$!";
        binmode UPLOADFILE;
        while (<$upload_filehandle>) {
            print UPLOADFILE;
        }
        close UPLOADFILE;

        # ID list file
        my $id_list_file = "";
        if ( $filename ) {
            my $mimetype = $cgi->uploadInfo($filename)->{'Content-Type'};
            my @valid_mimetypes = qw( application/octet-stream text/csv text/plain application/vnd.ms-excel );
            if ( grep { /^$mimetype$/ } @valid_mimetypes ) {
                if ( my $filefh = $cgi->upload("id_list_file") ) {
                    my @filter_record_ids;
                    my $filefullpath = $upload_dir . '/' . $filename;
                    open(FH, '<', $filefullpath) or die $!;
                    while(<FH>){
                        push @filter_record_ids, $_;
                    }
                    @filter_record_ids = map { my $id = $_; $id =~ s/[\r\n]*$//; $id } @filter_record_ids;
                    @filter_record_ids = uniq @filter_record_ids;
                    close(FH);
                    unlink $filefullpath or warn "Unable to unlink $filefullpath: $!";

                    $id_list_file = join(',', @filter_record_ids);
                }
            }
        }

        # Output format
        my $output_format = $cgi->param("output_format");
        $output_format = 'iso2709' if $output_format eq 'marc';

        my $start_datecreated = undef;
        my $end_datecreated = undef;
        my $start_datemodified = undef;
        my $end_datemodified = undef;

        if ($cgi->param("datecreatedmodified") eq "datecreated"){
            $start_datecreated = ( $cgi->param("start_datecreatedmodified") ) ? dt_from_string( scalar $cgi->param("start_datecreatedmodified") ) : undef;
            $end_datecreated   = ( $cgi->param("end_datecreatedmodified") ) ? dt_from_string( scalar $cgi->param("end_datecreatedmodified") ) : undef;
        }else{
            $start_datemodified = ( $cgi->param("start_datecreatedmodified") ) ? dt_from_string( scalar $cgi->param("start_datecreatedmodified") ) : undef;
            $end_datemodified   = ( $cgi->param("end_datecreatedmodified") ) ? dt_from_string( scalar $cgi->param("end_datecreatedmodified") ) : undef;
            if (defined $end_datemodified){
                $end_datemodified =~ s/00:00:00/23:59:59/g;
            }
        }

        $dbh->do(
            qq{
            INSERT INTO $table_jobs (`borrowernumber`, `record_type`, `authtype`, `branch`, `itemtype`, `start_datecreated`, `end_datecreated`, `start_datemodified`, `end_datemodified`, `start_accession`, `end_accession`, `start_callnumber`, `end_callnumber`, `id_list_file`, `starting_id`, `ending_id`, `export_remove_fields`, `dont_export_item`, `strip_items_not_from_libraries`, `excludesuppressedbiblios`, `output_format`, `csv_profile_id`, `filename`, `status`, `enqueued_on`, `mailto` ) VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )
           }
            , undef, ( $userid, $cgi->param("record_type"), $cgi->param("authtype") || '', $branches || '', $cgi->param("itemtype") || '', $start_datecreated, $end_datecreated, $start_datemodified, $end_datemodified,  ( $cgi->param("start_accession") ) ? dt_from_string( scalar $cgi->param("start_accession") ) : undef,  ( $cgi->param("end_accession") ) ? dt_from_string( scalar $cgi->param("end_accession") ) : undef,  $cgi->param("start_callnumber") || '',  $cgi->param("end_callnumber") || '', $id_list_file,  $starting_id,  $ending_id,  $cgi->param("export_remove_fields") || '',  ($cgi->param("dont_export_item") && $cgi->param("dont_export_item") eq "on")?1:0,  ($cgi->param("strip_items_not_from_libraries") && $cgi->param("strip_items_not_from_libraries") eq "on") ? 1 : 0, ($cgi->param("excludesuppressedbiblios"))?1:0,  $output_format,  $cgi->param("csv_profile_id") || 0,  $cgi->param("filename"), "new", dt_from_string, $mailto )
        );

        my $job_id = $dbh->last_insert_id(undef, undef, $table_jobs, undef);

        my $table_log = $self->get_qualified_table_name('log');
        $dbh->do(
            qq{
            INSERT INTO $table_log (`borrowernumber`, `job_id`, `action` ) VALUES ( ?, ?, ? );
           }
            , undef, ( $userid, $job_id, 'create' )
        );

        $template->param(jobid => $job_id);
    }

    print $cgi->header(
        {
            -type     => 'text/html',
            -charset  => 'UTF-8',
            -encoding => "UTF-8"
        }
    );

    print $template->output();
}

sub cronjob {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    
    my $today_iso     = output_pref( { dt => dt_from_string, dateonly => 1, dateformat => 'iso' } ) ;
    
    my $table_jobs = $self->get_qualified_table_name('jobs');
    my $store_directory = $self->retrieve_data('store_directory');
    $store_directory .= "/" unless ($store_directory =~ /\/$/);

    my @clean_chars;
    if ($self->retrieve_data('clean_chars')){
        @clean_chars = split ("\r\n", $self->retrieve_data('clean_chars'));
    }
    
    
    if ( not -w $store_directory) {
        print "ERROR: The directory $store_directory not writeable.\n";
        exit;
    }
    
    if ( $self->retrieve_data('enabled') ) {
        my $sth = $dbh->prepare("SELECT * FROM $table_jobs WHERE status = 'new'");
        $sth->execute();
        
        while ( my $row = $sth->fetchrow_hashref ) {

            my $systemfilename = "export-".$row->{id}."_".$today_iso."_".time();
            if ($row->{"output_format"} eq "xml"){
                $systemfilename .= ".xml";
            }elsif ($row->{"output_format"} eq "csv"){
                $systemfilename .= ".csv";
            }else{
                $systemfilename .= ".mrc";
            }
            
            print $tee "\nStarting job " . $row->{"id"} . "\n";
            print $tee "\t Record type: " . $row->{"record_type"} . "\n";
            print $tee "\t Format: " . $row->{"output_format"} . "\n";
            print $tee "\t Output: " . $store_directory . $systemfilename . "\n";
            
            # Start
            $dbh->do("UPDATE $table_jobs SET status = ?, started_on = ? WHERE id = ?", undef, ('started', dt_from_string, $row->{"id"}));
            
            my $libraries = Koha::Libraries->search_filtered->unblessed;
            
            my @branch;
            if ($row->{"branch"} ne ""){
                @branch = split (',', $row->{"branch"});
            }

            my $only_export_items_for_branches = $row->{"strip_items_not_from_libraries"} ? \@branch : undef;
            my @branchcodes;
            for my $branchcode ( @branch ) {
                if ( grep { $_->{branchcode} eq $branchcode } @$libraries ) {
                    push @branchcodes, $branchcode;
                }
            }
            
            my @biblionumbers_list;
            if ($row->{"id_list_file"}){
                @biblionumbers_list = split (',', $row->{"id_list_file"});
            }

            my @record_ids;
            
            if ( $row->{"record_type"} eq 'bibs' or $row->{"record_type"} eq 'auths' ) {
                unless (@record_ids) {
                    if ($row->{"record_type"} eq 'bibs') {
                        my $conditions = {
                            ($row->{"starting_id"} or $row->{"ending_id"})
                                ? (
                                "me.biblionumber" => {
                                    ($row->{"starting_id"} ? ('>=' => $row->{"starting_id"}) : ()),
                                    ($row->{"ending_id"} ? ('<=' => $row->{"ending_id"}) : ()),
                                }
                            )
                                : (),

                            ($row->{"start_datecreated"} or $row->{"end_datecreated"})
                                ? (
                                "biblio.datecreated" => {
                                    ($row->{"start_datecreated"} ? ('>=' => $row->{"start_datecreated"}) : ()),
                                    ($row->{"end_datecreated"} ? ('<=' => $row->{"end_datecreated"}) : ()),
                                }
                            )
                                : (),

                            ($row->{"start_datemodified"} or $row->{"end_datemodified"})
                                ? (
                                "me.timestamp" => {
                                    ($row->{"start_datemodified"} ? ('>=' => $row->{"start_datemodified"}) : ()),
                                    ($row->{"end_datemodified"} ? ('<=' => $row->{"end_datemodified"}) : ()),
                                }
                            )
                                : (),
                            
                            ($row->{"start_callnumber"} or $row->{"end_callnumber"})
                                ? (
                                'items.itemcallnumber' => {
                                    ($row->{"start_callnumber"} ? ('>=' => $row->{"start_callnumber"}) : ()),
                                    ($row->{"end_callnumber"} ? ('<=' => $row->{"end_callnumber"}) : ()),
                                }
                            )
                                : (),

                            ($row->{"start_accession"} or $row->{"end_accession"})
                                ? (
                                'items.dateaccessioned' => {
                                    ($row->{"start_accession"} ? ('>=' => $row->{"start_accession"}) : ()),
                                    ($row->{"end_accession"} ? ('<=' => $row->{"end_accession"}) : ()),
                                }
                            )
                                : (),
                            (@branchcodes ? ('items.homebranch' => { in => \@branchcodes }) : ()),
                            ($row->{"itemtype"}
                                ?
                                C4::Context->preference('item-level_itypes')
                                    ? ('items.itype' => $row->{"itemtype"})
                                    : ('me.itemtype' => $row->{"itemtype"})
                                : ()
                            ),

                        };

                        my $biblioitems = Koha::Biblioitems->search($conditions, { join => { 'biblio' => 'items' }, columns => 'biblionumber' });
                        while (my $biblioitem = $biblioitems->next) {
                            push @record_ids, $biblioitem->biblionumber;
                        }
                    }
                    elsif ($row->{"record_type"} eq 'auths') {
                        my $conditions = {
                            ($row->{"starting_id"} or $row->{"ending_id"})
                                ? (
                                authid => {
                                    ($row->{"starting_id"} ? ('>=' => $row->{"starting_id"}) : ()),
                                    ($row->{"ending_id"} ? ('<=' => $row->{"ending_id"}) : ()),
                                }
                            )
                                : (),
                            ($row->{"authtype"} ? (authtypecode => $row->{"authtype"}) : ()),
                        };
                        
                        my $authorities = Koha::Database->new->schema->resultset('AuthHeader')->search($conditions);
                        @record_ids = map {$_->authid} $authorities->all;
                    }
                }

                @record_ids = uniq @record_ids;
                if ( @record_ids and scalar(@biblionumbers_list) ) {
                    # intersection
                    my %record_ids = map { $_ => 1 } @record_ids;
                    @record_ids = grep $record_ids{$_}, @biblionumbers_list;
                }
                
                if (@record_ids && scalar(@record_ids)){
                    # Do the export job
                    $dbh->do("UPDATE $table_jobs SET status = ? WHERE id = ?", undef, ('inprogress', $row->{"id"}));

                    my $systemfilename_codification = "export-".$row->{id}."_".$today_iso."_".time().'_codification_changed.csv';

                    Koha::Exporter::Record::export(
                        { record_type                      => $row->{"record_type"},
                            record_ids                     => \@record_ids,
                            format                         => $row->{"output_format"},
                            dont_export_fields             => $row->{"export_remove_fields"},
                            csv_profile_id                 => $row->{"csv_profile_id"},
                            export_items                   => (not $row->{"dont_export_item"}),
                            only_export_items_for_branches => $only_export_items_for_branches,
                            output_filepath                => $store_directory . $systemfilename,
                            clean_chars                    => \@clean_chars,
                            exclude_suppressed_biblios     => $row->{"excludesuppressedbiblios"},
                            output_filepath_codification   => $store_directory . $systemfilename_codification,
                        }
                    );

                    # Zip the file
                    my $zip = Archive::Zip->new();
                    my $file_member = $zip->addFile( $store_directory . $systemfilename, basename($store_directory . $systemfilename) );

                    unless ( $zip->writeToFileNamed($store_directory . $systemfilename. '.zip') == AZ_OK ) {
                        print "ERROR: Zip write error\n";
                    }else{
                        unlink $store_directory . $systemfilename || warn "ERROR: Cannot remove " . $store_directory . $systemfilename . "\n";
                    }

                    # Finish
                    $dbh->do("UPDATE $table_jobs SET status = ?, ended_on = ? WHERE id = ?", undef, ('finished', dt_from_string, $row->{"id"}));
                    $dbh->do("UPDATE $table_jobs SET systemfilename = ? WHERE id = ?", undef, ($systemfilename . ".zip", $row->{"id"}));
                    $dbh->do("UPDATE $table_jobs SET systemfilename_codification = ? WHERE id = ?", undef, ($systemfilename_codification , $row->{"id"}));
                }else{
                    $dbh->do("UPDATE $table_jobs SET status = ?, information = ?, ended_on = ? WHERE id = ?", undef, ('error', 'No data to export', dt_from_string, $row->{"id"}));
                }

                if ($row->{"mailto"}){
                    my $from    = C4::Context->preference('KohaAdminEmailAddress');
                    my $patron = Koha::Patrons->find($row->{borrowernumber});
                    
                    # prepare the email
                    my $letter = C4::Letters::GetPreparedLetter(
                        module      => 'backgroundjobs',
                        letter_code => 'EXPORTPLUGIN',
                        branchcode  => $patron->branchcode,
                        lang        => $patron->lang,
                        tables      => { 'borrowers' => $patron->borrowernumber },
                    );

                    my $mailqueued = C4::Letters::EnqueueLetter(
                        {   letter                 => $letter,
                            borrowernumber         => $patron->borrowernumber,
                            message_transport_type => 'email',
                            from_address           => $from,
                            to_address             => $row->{"mailto"},
                        }
                    );

                    unless ($mailqueued){
                        print "ERROR: Error sending email to ".$row->{"mailto"}."\n";
                    }
                }
            }
        }
    }else{
        print "The plugin is not active, please contact with your administrator\n";
    }
    
    return 1;
}

1;

__END__

=head1 NAME

Export.pm - Koha Plugin Export.

=head1 SYNOPSIS

Koha Plugin Export

=head1 DESCRIPTION

Koha Plugin Export

=head1 AUTHOR

Juan Francisco Romay Sieira <juan.sieira AT xercode DOT es>

=head1 COPYRIGHT

Copyright 2020 Xercode Media Software S.L.

=head1 LICENSE

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later version.

You should have received a copy of the GNU General Public License along with Koha; if not, write to the Free Software Foundation, Inc., 51 Franklin Street,
Fifth Floor, Boston, MA 02110-1301 USA.

=head1 DISCLAIMER OF WARRANTY

Koha is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

=cut
