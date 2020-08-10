#!/usr/bin/perl
#
# Copyright 2020 Xercode Media Software S.L.
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use C4::Context;
use C4::Log;
use Koha::Email;
use Koha::DateUtils;

use Getopt::Long qw(:config auto_help auto_version);
use Pod::Usage;
use MIME::Lite;
use CGI qw ( -utf8 );
use Carp;
use Encode;
use File::Copy;
use File::Temp;
use File::Basename qw( dirname );
use Scalar::Util qw(looks_like_number);

BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/../kohalib.pl" };
}

=head1 NAME

run.pl - Run pre-existing jobs

=head1 SYNOPSIS

runbackgroundjobs.pl [ -h | -v ]

 Options:
   -h --help       brief help message
   -v              verbose

=head1 OPTIONS

=over

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<-v>

Verbose. Without this flag set, only fatal errors are reported.

=back

=head1 DESCRIPTION

This script is designed to run existing export jobs.

=head1 USAGE EXAMPLES

B<run.pl>

=cut

# These variables can be set by command line options,
# initially set to default values.

my $help    = 0;
my $verbose = 0;


GetOptions(
    'help|?'            => \$help,
    'verbose'           => \$verbose,
) or pod2usage(2);

pod2usage( -verbose => 2 ) if ($help and $verbose);
pod2usage(1) if $help;

cronlogaction();

my $dbh = C4::Context->dbh;
my $today = dt_from_string();

my $results_dir   = ;
my $today_iso     = output_pref( { dt => dt_from_string, dateonly => 1, dateformat => 'iso' } ) ;

if( not -w $results_dir) {
    print "The directory $results_dir is not writable!\n";
    exit;
}
$results_dir = $1 if($results_dir =~ /(.*)\/$/);

my @pending = GetBrackgroundJobs("scheduled_report", "new");

# In progress
foreach my $item (@pending){
    &SetBackgroundJobStatus($item->{id}, "inprogress");
}

foreach my $item (@pending){
    my $filename = "report-".$item->{id}."_".$today_iso."_".time();
    &SetBackgroundJobStatus($item->{id}, "started");
    $verbose and print "Running job ID ".$item->{id}."\n";

    my $data =  from_json($item->{data});

    next unless ($data->{'report_id'});
    my $report = Koha::Reports->find( $data->{'report_id'} );

    next unless ($report);

    if ($data->{'options'}->{'format'} && $data->{'options'}->{'format'} ne ""){
        $format = $data->{'options'}->{'format'};
    }
    $filename .= ".".$format;

    my $sql         = $report->savedsql;
    my $report_name = $report->report_name;
    my $type        = $report->type;

    $sql = get_prepped_report( $sql, $data->{'report_params'}, $data->{'report_values'});
    $sql = _parse_equal_to_null ($item->{id}, $sql);

    $verbose and print "SQL: $sql\n\n";

    # Execution time
    my $start = DateTime->now;

    my ($sth, $error) = _execute_query( $sql, undef, undef, undef, $data->{'report_id'} );

    # Execution time
    my $end = DateTime->now;
    print "End time : $end \n";
    my $elapsedtime = ($end->subtract_datetime($start))->seconds;
    if($elapsedtime){
        my $sth = $dbh->prepare('UPDATE saved_sql SET execution_time = ? WHERE id = ? ');
        $sth->execute($elapsedtime, $data->{'report_id'});
    }
    # END Execution time

    # Counter
    my $sthUpdate = $dbh->prepare("UPDATE saved_sql SET counter = ? WHERE id = ?");
    $sthUpdate->execute($report->counter + 1, $data->{'report_id'});
    # END Counter

    if ($error){
        print "\nERROR: ".$error."\n";
        &SetBackgroundJobStatus($item->{id}, "error");
        $data->{'messages'}->{'error'} = $error;
        my $_data = to_json( $data, {pretty => 1});
        &ModBackgroundJobData($item->{id}, $_data);
        next;
    }

    my $count = scalar($sth->rows);

    $verbose and print "$count results from execute_query\n";
    $data->{'messages'}->{'report_count'} = $count;

    my $message;
    if ($format eq 'csv') {
        my $csv = Text::CSV::Encoded->new({
            encoding_out => 'utf8',
            binary      => 1,
            quote_char  => $quote,
            sep_char    => $separator,
            });

        if ( $csv_header ) {
            my @fields = map { decode( 'utf8', $_ ) } @{ $sth->{NAME} };
            $csv->combine( @fields );
            $message .= $csv->string() . "\n";
        }

        while (my $line = $sth->fetchrow_arrayref) {
            $csv->combine(@$line);
            $message .= $csv->string() . "\n";
        }
        writeToFile($results_dir."/".$filename, $message);
        $data->{'messages'}->{'report_results'} = $filename;
    } elsif ( $format eq 'ods' ) {
        $type = 'application/vnd.oasis.opendocument.spreadsheet';
        my $ods_fh = File::Temp->new( UNLINK => 0 );
        my $ods_filepath = $ods_fh->filename;

        use OpenOffice::OODoc;
        my $tmpdir = dirname($ods_filepath);
        odfWorkingDirectory( $tmpdir );
        my $container = odfContainer( $ods_filepath, create => 'spreadsheet' );
        my $doc = odfDocument (
            container => $container,
            part      => 'content'
        );
        my $table = $doc->getTable(0);
        my @headers = header_cell_values( $sth );
        my $rows = $sth->fetchall_arrayref();
        my ( $nb_rows, $nb_cols ) = ( 0, 0 );
        $nb_rows = @$rows;
        $nb_cols = @headers;
        $doc->expandTable( $table, $nb_rows + 1, $nb_cols );

        my $row = $doc->getRow( $table, 0 );
        my $j = 0;
        for my $header ( @headers ) {
            $doc->cellValue( $row, $j, $header );
            $j++;
        }
        my $i = 1;
        for ( @$rows ) {
            $row = $doc->getRow( $table, $i );
            for ( my $j = 0 ; $j < $nb_cols ; $j++ ) {
                my $value = Encode::encode( 'UTF8', $rows->[$i - 1][$j] );
                if ($value){
                    $doc->cellValueType( $row, $j, 'float') if ($value =~ m/^[0-9.E]+$/ && not $value =~ m/^0/);
                    $doc->cellValue( $row, $j, $value );
                }
            }
            $i++;
        }
        $doc->save();
        move($ods_filepath, $results_dir."/".$filename);
        chmod 0755, $results_dir."/".$filename;
        $data->{'messages'}->{'report_results'} = $filename;
    }

    my $to = $data->{'options'}->{'to'} or C4::Context->preference('KohaAdminEmailAddress');

    if ($to){
        my $from    = $data->{'options'}->{'from'} or C4::Context->preference('KohaAdminEmailAddress');

        my $subject = $data->{'options'}->{'subject'};

        if ( !$subject || $subject eq "" )
        {
            if ( defined($report_name) and $report_name ne "")
            {
                $subject = $report_name ;
            }
            else
            {
                $subject = 'Koha Saved Report';
            }
        }

        my $patron = Koha::Patrons->find($item->{borrowernumber});

        my $uuidLink = C4::Context->preference('staffClientBaseURL')."/cgi-bin/koha/tools/background_jobs.pl?op=view&id=".$item->{id};

        # prepare the email
        my $letter = C4::Letters::GetPreparedLetter(
            module      => 'backgroundjobs',
            letter_code => 'SCHEDULED_REPORT',
            branchcode  => $patron->branchcode,
            lang        => $patron->lang,
            substitute =>
              { reporturl => $uuidLink },
        );

        if ($subject ne ""){
            $letter->{'title'} = $subject;
        }

        my $mailqueued = C4::Letters::EnqueueLetter(
            {   letter                 => $letter,
                borrowernumber         => $patron->borrowernumber,
                message_transport_type => 'email',
                from_address           => $from,
                to_address             => $to,
            }
        );

        if ($mailqueued){
            &SetBackgroundJobStatus($item->{id}, "finished");
            $verbose and print "\nMail enqueued\n";
        }else{
            &SetBackgroundJobStatus($item->{id}, "error");
            $data->{'messages'}->{'error'} = "Error sending email";
            $verbose and print "\nERROR: Mail not enqueued\n";
        }
    }else{
        &SetBackgroundJobStatus($item->{id}, "finished");
        $verbose and print "\nMail not enqueued, there is no email to send the information\n";
    }

    my $_data = to_json( $data, {pretty => 1});
    &ModBackgroundJobData($item->{id}, $_data);
    $verbose and print "\nJobs finished\n";
}

# Remove old jobs
my @oldjobs = GetOldBrackgroundJobs("scheduled_report");

foreach (@oldjobs){
    my $job = Koha::BackgroundJobs->find($_->{id});
    next unless ($job);
    $job->remove;
}


sub get_prepped_report {
    my ($sql, $param_names, $sql_params ) = @_;
    my %lookup;
    @lookup{@$param_names} = @$sql_params;
    my @split = split /<<|>>/,$sql;
    my @tmpl_parameters;
    for(my $i=0;$i<$#split/2;$i++) {
        my $quoted = @$param_names ? $lookup{ $split[$i*2+1] } : @$sql_params[$i];
        # if there are special regexp chars, we must \ them
        $split[$i*2+1] =~ s/(\||\?|\.|\*|\(|\)|\%)/\\$1/g;
        if ($split[$i*2+1] =~ /\|\s*date\s*$/) {
            $quoted = output_pref({ dt => dt_from_string($quoted), dateformat => 'iso', dateonly => 1 }) if $quoted;
        }
        $quoted = C4::Context->dbh->quote($quoted);
        $sql =~ s/<<$split[$i*2+1]>>/$quoted/;
    }
    return $sql;
}

sub _parse_equal_to_null {
    my ($report_id, $query) = @_;

    # Equal operator
    my $finishhim = 0;
    $query =~ s/ where / WHERE /g;
    while (my ($sqlequal) = $query =~ /([\.a-z0-9]*\s+\=\s+\'\')/) {
    	last unless $sqlequal;
    	if ($sqlequal eq ' = \'\''){
    		$query =~ s/$sqlequal/ \=\=\=\= ''/;
    		next;
    	}
    	my @parts = split '=', $sqlequal;
    	my $_sqlequal = $sqlequal;

    	$_sqlequal =~ s/ \= / \=\=\=\= /g;
    	$parts[0] =~ s/^\s+|\s+$//g;
    	my $sqlequalreplacement = "($_sqlequal OR $parts[0] IS NULL)";
    	$query =~ s/$sqlequal/$sqlequalreplacement/;
    	$finishhim++;
    	last if $finishhim >= 100;
    }

    if ($finishhim >= 100){
    	#logaction( "REPORTS", "MODIFY", $report_id, "ERROR WHILE \"=\" > 100: $query" ) if C4::Context->preference("ReportsLog");
    }

    # "LIKE" operator
    $query =~ s/ like / LIKE /g;
    $finishhim = 0;
    while (my ($sqlequal) = $query =~ /([\.a-z0-9]*\s+LIKE\s+\'\')/) {
    	last unless $sqlequal;
    	if ($sqlequal eq ' LIKE \'\''){
    		$query =~ s/$sqlequal/ \=\=\=\= ''/;
    		next;
    	}
    	my $sqlequalorig = $sqlequal;
    	$sqlequal =~ s/LIKE/\=/g;

    	my @parts = split '=', $sqlequal;
    	my $_sqlequal = $sqlequal;

    	$_sqlequal =~ s/\=/\=\=\=\=/g;
    	$parts[0] =~ s/^\s+|\s+$//g;
    	my $sqlequalreplacement = "($_sqlequal OR $parts[0] IS NULL)";
    	$query =~ s/$sqlequalorig/$sqlequalreplacement/;
    	$finishhim++;
    	last if $finishhim >= 100;
    }

    if ($finishhim >= 100){
    	logaction( "REPORTS", "MODIFY", $report_id, "ERROR WHILE \"LIKE\" > 100: $query" ) if C4::Context->preference("ReportsLog");
    }

    $query =~ s/\=\=\=\=/\=/g;

    return $query;
}

sub _execute_query {

    my ( $sql, $offset, $limit, $sql_params, $report_id ) = @_;

    $sql_params = [] unless defined $sql_params;

    # check parameters
    unless ($sql) {
        carp "_execute_query() called without SQL argument";
        return;
    }

    if ($sql =~ /;?\W?(UPDATE|DELETE|DROP|INSERT|SHOW|CREATE)\W/i) {
        return (undef, $1 );
    } elsif ($sql !~ /^\s*SELECT\b\s*/i) {
        return (undef, 'Missing SELECT' );
    }

    my $dbh = C4::Context->dbh;

    $dbh->do( 'UPDATE saved_sql SET last_run = NOW() WHERE id = ?', undef, $report_id ) if $report_id;

    my $sth = $dbh->prepare($sql);

    eval {
        $sth->execute(@$sql_params);
    };

    my $error = 0;
    if ( $@ ) {
        $error = 1;
    }

    return ( $sth, $sth->errstr ) if ($sth->err || $error);
    return ( $sth );
}


sub writeToFile {
    my $file = shift;
    my $string = shift;

    open(FILEHANDLE, ">".$file) or die 'cannot open file!';
    binmode(FILEHANDLE, ":utf8");
    print FILEHANDLE $string."\n";
    close (FILEHANDLE);
    chmod 0755, $file;
}

sub header_cell_values {
    my $sth = shift or return ();
    return '' unless ($sth->{NAME});
    return @{$sth->{NAME}};
}


