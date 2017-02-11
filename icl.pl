#!/usr/bin/perl

# Copyright (c) 2012,2013 Scalable Informatics
# This is free software, see the gpl-2.0.txt 
# file included in this distribution


use strict;
use English '-no_match_vars';
use Getopt::Lucid qw( :all );
use POSIX qw[strftime];
#use SI::Utils;
use constant true => 1==1;
use constant false => 1==0;
use IPC::Run qw( start pump finish timeout run harness );
use Data::Dumper;
use IO::Handle;
use Time::HiRes qw( usleep ualarm gettimeofday tv_interval nanosleep
                             clock_gettime clock_getres clock_nanosleep clock
                             stat );
use Config::JSON;
use Digest::SHA  qw(sha256_hex);

use threads;
use threads::shared;

use constant config_path => ($OSNAME != /MSWin32/i ? '/opt/scalable/etc/icl.json' : 'c:\opt\scalable\etc\icl.json') ;

#
my $vers    = "0.7";


# variables
my ($opt,$rc,$version,$thr);
my $debug 		: shared;
my $verbose		: shared;
my $help;
my $dir			: shared;
my $system_interval	: shared;
my $block_interval	: shared;
my $done		: shared;
my $timestamp           : shared;
my (@systems,$system,$thr_name,$sys,$sys_hash);
my ($host,$user,$pass,$output,$config_file,$cf_h,$config,$c);




# signal catcher
# SIGHUP is a graceful exit, SIGKILL and SIGINT are immediate
my (@sigset,@action);
foreach (0 .. 2 ) { $sigset[$_] = POSIX::SigSet->new() };
$action[0] = POSIX::SigAction->new('sig_handler_graceful' ,$sigset[0],&POSIX::SA_NODEFER);
$action[1] = POSIX::SigAction->new('sig_handler_immediate',$sigset[1],&POSIX::SA_NODEFER);
$action[2] = POSIX::SigAction->new('sig_handler_immediate',$sigset[2],&POSIX::SA_NODEFER);
POSIX::sigaction(&POSIX::SIGHUP,  $action[0]);
POSIX::sigaction(&POSIX::SIGKILL, $action[1]);
POSIX::sigaction(&POSIX::SIGINT,  $action[2]);

sub sig_handler_graceful {
	our $out_fh;
	print STDERR "caught graceful termination signal\n";
	$done	= true;
        close($out_fh) if (defined($out_fh) && $out_fh);
	# exit gracefully
}

sub sig_handler_immediate {
	our $out_fh;
	print STDERR "caught immediate termination signal\n";
	$done	= true;
        close($out_fh) if (defined($out_fh) && $out_fh);
	# exit -1;
	# exit immediately
	die "thread caught termination signal\n";
}



 
my @command_line_specs = (
		     Param("config|c"),
                     Switch("help"),
                     Switch("version"),
                     Switch("debug"),
                     Switch("verbose"),
                     );

# parse all command line options
eval { $opt = Getopt::Lucid->getopt( \@command_line_specs ) };
if ($@) 
  {
    #print STDERR "$@\n" && help() && exit 1 if ref $@ eq 'Getopt::Lucid::Exception::ARGV';
    print STDERR "$@\n\n" && help() && exit 2 if ref $@ eq 'Getopt::Lucid::Exception::Usage';
    print STDERR "$@\n\n" && help() && exit 3 if ref $@ eq 'Getopt::Lucid::Exception::Spec';
    #printf STDERR "FATAL ERROR: netmask must be in the form x.y.z.t where x,y,z,t are from 0 to 255" if ($@ =~ /Invalid parameter netmask/);
    ref $@ ? $@->rethrow : die "$@\n\n";
  }

# test/set debug, verbose, etc
$debug      = $opt->get_debug   ? true : false;
$verbose    = $opt->get_verbose ? true : false;
$help       = $opt->get_help    ? true : false;
$version    = $opt->get_version ? true : false;
$config_file= $opt->get_config  ? $opt->get_config  : config_path;

$done       	= false;

&help()             if ($help);
&version($vers)     if ($version);

$config 	= &parse_config_file($config_file);

# start time stamp thread
$thr->{TS}                      = threads->create({'void' => 1},'TS');

# loop through all the machines in the config file, and
$sys_hash 	= $config->{'config'}->{'systems'};
@systems	= keys(%{$sys_hash});

foreach $system (@systems)
   {
      $sys 		= $sys_hash->{$system};
      $thr_name 	= sprintf 'icm.%s',sha256_hex($system);
      $thr->{$thr_name}	= threads->create({'void' => 1},'ipmi_console_monitor',$sys,$system);
   }


# main loop ... lots of sleeping ...
do {
    usleep(100000);
} until ($done);


exit 0;

 
sub help {
printf<<EOH;
new.pl :   new.pl does this stuff


EOH

exit 0;
}

sub version {
    my $V = shift;
    print "new.pl version $V\n";
    exit 0;
}

sub ipmi_console_monitor {
    my $sys		= shift;
    my $name		= shift;
    	
    $done	        = false;
    my $interval        = 1000000; # microseconds to sleep before waking
    my ($in,$out,$err,@lines,@times,$ts,$h,$ipmi,@cmd,$out_fh,$out_fn);
    my ($lineout,$r);
    my $ipmihost	= $sys->{'ipmi_addr'};
    my $ipmiuser	= $sys->{'ipmi_user'};
    my $ipmipass	= $sys->{'ipmi_pass'};
    
    
    $out_fn	= sprintf '%s.log',$name;
    open($out_fh,">>".$out_fn)   if ($out_fn);
    
    # disable any existing ipmi serial over lan connections before enabling ours
    $r = run (sprintf "/usr/bin/ipmitool -I lanplus -H %s -U %s -P %s -c sol deactivate",
                          $ipmihost,
                          $ipmiuser,
                          $ipmipass);
    
    # start ipmi serial over lan
    $ipmi		= sprintf "/usr/bin/ipmitool -v -I lanplus -H %s -U %s -P %s  sol activate",
                          $ipmihost,
                          $ipmiuser,
                          $ipmipass;
    
    @cmd			= split(/\s+/,$ipmi);
    
    
     
    # create the run harness
    $out 	= "";
    $in	        = "\n\n\n\n";
    $h = start \@cmd, '<pty<', \$in, '>pty>', \$out,  debug=>$debug;
#    $|          = 1;
    $in         = "";
    do
       {
        printf "time: %f\n",$timestamp if (false);  
        if ($h->pumpable)
           {
            $h->pump_nb;
           }
          else
           {
            $done = true;
           }
        
        if ($out ne "")
           {
            @lines	= split(/\n/,$out);
            $out    = "";
	    open($out_fh,">>".$out_fn)   if ($out_fn);
            foreach my $line (@lines) 
              {
                # get timestamp data
                if ($out_fn)
                   {
                    printf $out_fh "%i %s\n",$timestamp,$line;
                   }
                  else
                   {
                    printf "%i %s\n",$timestamp,$line;
                   }
              }            
	    close($out_fh) if ($output);
           }
        usleep($interval);    
       } until ($done);
}

sub TS {
    my $sleep_interval  = 250000; # microseconds to sleep before waking
    my $last = 0;
    do {
        $timestamp  = time();
        if ((int($timestamp - $last) >= 1)) {
            printf "time: %f\n",$timestamp if ($debug);
            $last = $timestamp;
        }
        
        usleep($sleep_interval);    
    } until ($done);
}

sub parse_config_file {
    my $file	= shift;
    my $rc;
    if (-e $file) {
	if (-r $file) {
		$rc = Config::JSON->new($file);		
	}
	else
	{
		die "FATAL ERROR: config file \'$config_file\' exists but is unreadable by this userid\n";
	}
	
	#code
    }
    else
    {
	die "FATAL ERROR: config file \'$config_file\' does not exist\n";
    }
    return $rc;
}
