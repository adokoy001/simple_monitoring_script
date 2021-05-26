use strict;
use warnings;
use utf8;
use Encode;
use FindBin;
use Safe;
use Mojo::UserAgent;
use Mojo::SQLite;
use IO::Socket::SSL;
my $base_dir = $FindBin::Bin . '/';

unless(-f $base_dir.'.gitignore'){
    my $gitignore = "config.conf
monitor.db";
    open(my $fh, ">", $base_dir.'.gitignore');
    print $fh $gitignore;
    close($fh);
}

unless(-f $base_dir.'config.conf'){
    my $config_content = "{
        slack_url => 'https://hooks.slack.com/services/YOUR_SLACK_HOOK',
        sqlite => 'monitor.db',
        external => [
                 {name => 'EXAMPLE', url => 'https://example.com'},
        ],
}";
    open(my $fh, ">", $base_dir.'config.conf');
    print $fh $config_content;
    close($fh);
    print "config.conf was generated automatically.\n";
}

my $config = &load_config($base_dir.'config.conf');

my $dbfile_first_flag = 0;
unless(-f $base_dir.$config->{'sqlite'}){
    $dbfile_first_flag = 1;
}

my $sqlite = Mojo::SQLite->new('sqlite:'.$config->{'sqlite'});

if($dbfile_first_flag){
    $sqlite->db->query('CREATE TABLE monitor_log( url text, last_detect timestamp)');
}

my $url = $config->{'slack_url'};
my $external = $config->{'external'};

my $ext_ua = Mojo::UserAgent->new;

for(0 .. $#$external){
    my $instance = $external->[$_];
    my $code = 1000;
    my $additional_message = '';
    eval{
        $code = $ext_ua->get($instance->{url})->result->code;
    };
    if($@){
        $additional_message = $@;
    }
    unless(($code >= 200) and ($code <= 404)){
        my $send_flag = 0;
        my $counted = $sqlite
            ->db
            ->query('select count(*) as counted from monitor_log where url = ?',$instance->{url})
            ->hash->{counted};
        if($counted == 0){
            $sqlite->db->insert('monitor_log',{url => $instance->{url}, last_detect => time()});
            $send_flag = 1;
        }else{
            my $last_detect = $sqlite
                ->db
                ->query('select last_detect from monitor_log where url = ?',$instance->{url})
                ->hash->{last_detect};
            if(time() - $last_detect > 3600){
                $send_flag = 1;
            }else{
                $send_flag = 0;
            }
            $sqlite->db->delete('monitor_log',{url => $instance->{url}});
            $sqlite->db->insert('monitor_log',{url => $instance->{url}, last_detect => time()});
        }
        if($send_flag == 1){
            my $message = '```'."SERVER MONITORING ALERT!!\n";
            $message .= "SERVICE NAME  : ".$instance->{name}."\n";
            if($code == 1000){
                $message .= "ADDITIONAL    : $additional_message\n";
            }
            $message .= "RESPONSE CODE : ".$code."\n".'```';
            my $tmp_res = $ext_ua->post(
                $url
                =>
                { 'Content-type' => 'application/json' }
                =>  json => { text => $message }
                )->result;
        }
    }
}


sub load_config{
    my $filename = shift;
    open(my $fh, "<", $filename);
    my $content = '';
    while(<$fh>){$content .= $_;}
    close($fh);
    my $safe = Safe->new;
    my $config = $safe->reval($content) or die "$!$@";
    return $config;
}
