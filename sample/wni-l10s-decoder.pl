#!/usr/local/bin/perl -w

use utf8;
use strict;
use warnings;
use LWP;
use IO::Socket;
use DateTime;
use Digest::MD5 qw(md5_hex);
use Time::Local;
use Earthquake::EEW::Decoder;

#################################################################
my $USER = ''; #WNI L10Sユーザー名
my $PASS = ''; #WNI L10Sパスワード
#################################################################
my $DEBUG = 0;
my $HOST = 'http://lst10s-sp.wni.co.jp/server_list.txt';
my $UserAgent = 'FastCaster/1.0 powered by weathernews.';
my $ServerVer = 'FastCaster/1.0.0 (Unix)';
my $TerminalID = '211363088';
my $AppVer = '2.2.4.0';
#################################################################
my $PASS_md5 = md5_hex($PASS);
my $dt = DateTime->now;
my $now = $dt->strftime("%Y/%m/%d %H:%M:%S.%6N");
my $eew = Earthquake::EEW::Decoder->new();

WNI_INIT:
my ( $ip, $port ) = &initWNI;
my $socket = IO::Socket::INET->new(
    PeerAddr => $ip,
    PeerPort => $port,
    Proto => "tcp",
);

my $request = HTTP::Headers->new(
    'User-Agent' => $UserAgent,
    'Accept' => '*/*',
    'Cache-Control' => 'no-cache',
    'X-WNI-Account' => $USER,
    'X-WNI-Password' => $PASS_md5,
    'X-WNI-Application-Version' => $AppVer,
    'X-WNI-Authentication-Method' => 'MDB_MWS',
    'X-WNI-ID' => 'Login',
    'X-WNI-Protocol-Version' => '2.1',
    'X-WNI-Terminal-ID' => $TerminalID,
    'X-WNI-Time' => $now
);

$socket->send("GET /login HTTP/1.0\n");
$socket->send( $request->as_string );
$socket->send("\n");

my $PP = 1;
my $data_length = 0;
my $LAST_ID_NUM = '';
while ( my $buf = <$socket> ) {
    if ( $buf =~ /GET \/ HTTP\/1.1/ ) {
        my $dt = DateTime->now;
        my $now = $dt->strftime("%Y/%m/%d %H:%M:%S.%6N");
        my $response = HTTP::Headers->new(
            'Content-Type' => 'application/fast-cast',
            'Server' => $ServerVer,
            'X-WNI-ID' => 'Response',
            'X-WNI-Result' => 'OK',
            'X-WNI-Protocol-Version' => '2.1',
            'X-WNI-Time' => $now
        );
        $socket->send("HTTP/1.0 200 OK\n");
        $socket->send( $response->as_string );
        $socket->send("\n");
        $socket->flush();
        $PP = 1;
        $data_length = 0;
    }
    elsif ( $buf =~ /^Content-Length: (\d+)/ ) {
        $data_length = $1;
    }
    elsif ( $buf =~ /^[\r\n]+$/ ) {
        $PP = 0;
        if ($data_length) {
            my $data = '';
            read( $socket, $data, $data_length );
            my $d = $eew->read_data($data);

            if ( !$d->{'warn_num'} ) {
                $data_length = 0;
                next;
            }
            my $NOW_ID_NUM = $d->{'eq_id'} . $d->{'warn_num'};
            if ( $d->{'eq_id'}
                && $d->{'warn_num'}
                && $LAST_ID_NUM eq $NOW_ID_NUM )
            {
                $data_length = 0;
                next;
            }
            my $before =
              &seconds( $d->{'warn_time'} ) - &seconds( $d->{'eq_time'} );
            my $warn_time = sprintf "20%d%d/%d%d/%d%d %d%d:%d%d:%d%d",
              ( split //, $d->{'warn_time'} );
            my $eq_time = sprintf "20%d%d/%d%d/%d%d %d%d:%d%d:%d%d",
              ( split //, $d->{'eq_time'} );

            my $warn_num_f = '';
            if ( $d->{'warn_num'} =~ /^9(\d\d)/ ) {
                $d->{'warn_num'} = $1 * 1;
                $warn_num_f = ' (最終報)';
            }
            my $str = '[第'
              . $d->{'warn_num'} . '報'
              . $warn_num_f . '] '
              . $d->{'center_name'} . ' '
              . $d->{'shindo'} . ' '
              . $eq_time . '('
              . $before
              . '秒前)発生' . "\n";

            $str .= '-地震ID:' . $d->{'eq_id'} . "\n";
            $str .=
              '-発生時間:' . $eq_time . '(' . $before . '秒前)' . "\n";
            $str .= '-発表時間:' . $warn_time . "\n";
            $str .=
                '-震央:'
              . $d->{'center_lat'} . '/'
              . $d->{'center_lng'} . '('
              . $d->{'center_name'} . ' '
              . $d->{'eq_place'} . ')'
              . $d->{'center_accurate'}
              . ' 深さ'
              . $d->{'center_depth'} . "km\n";
            $str .=
                '-最大: マグニチュード'
              . $d->{'magnitude'} . ' ('
              . $d->{'magnitude_accurate'} . ') '
              . $d->{'shindo'} . "\n";

            foreach my $type ( 'PAI', 'PPI', 'PBI' ) {
                $str .= '-' . $d->{$type}->{'name'} . "\n"
                  if ( $d->{$type}->{'name'} );
                foreach my $key ( keys %{ $d->{$type} } ) {
                    $str .= '--' . $d->{$type}->{$key}->{'name'} . "\n"
                      if ( $d->{$type}->{$key}->{'name'} );
                }
            }

            $str .= '-' . $d->{'EBI'}->{'name'} . "\n"
              if ( $d->{'EBI'}->{'name'} );
            foreach my $key ( keys %{ $d->{'EBI'} } ) {
                if ( $d->{'EBI'}->{$key}->{'name'} ) {
                    my $reach_time = sprintf "%d%d:%d%d:%d%d",
                      ( split //, $d->{'EBI'}->{$key}->{'time'} );
                    my $arrive = '';
                    $arrive = '(' . $d->{'EBI'}->{$key}->{'arrive'} . ')'
                      if ( $d->{'EBI'}->{$key}->{'arrive'} );
                    $str .= '--'
                      . $d->{'EBI'}->{$key}->{'name'}
                      . ' 到達時間：'
                      . $reach_time . ' '
                      . $arrive
                      . ' 予想震度:'
                      . $d->{'EBI'}->{$key}->{'shindo2'} . '～'
                      . $d->{'EBI'}->{$key}->{'shindo1'};
                    $str .= "\n";
                }
            }
            print $str , "\n";
            $LAST_ID_NUM = $d->{'eq_id'} . $d->{'warn_num'};
        }
        $data_length = 0;
    }
    elsif ( $buf =~ /X-WNI-Result: (.+)$/ ) {
        print $1,"\n";
    }
    elsif ( !$PP ) {
        print $PP, ':', $buf if ($DEBUG);
        chomp $buf;
    }
    elsif ($DEBUG) {
        print $PP, ':', $buf;
        chomp $buf;
    }
}
$socket->close();
goto WNI_INIT;
exit 255;

sub seconds {
    my ($str) = @_;
    if ( $str =~ /(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/ ) {
        return timelocal( $6, $5, $4, $3, $2 - 1, $1 + 2000 );
    }
    else {
        return -1;
    }
}

sub initWNI {
    my @SERVERS;
    my $ua = LWP::UserAgent->new;
    $ua->agent($UserAgent);

    my $req = HTTP::Request->new( GET => $HOST );
    my $res = $ua->request($req);
    if ( $res->is_success ) {
        @SERVERS = split /[\r\n]+/, $res->content;
    }
    else {
        print "Error: " . $res->status_line . "\n";
        exit;
    }

    my $sum = @SERVERS;
    my ( $ip, $port ) = split /:/, $SERVERS[ int( rand($sum) ) ];
    return ( $ip, $port );
}

