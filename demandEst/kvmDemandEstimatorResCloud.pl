#!/usr/bin/perl -w
# KVM Demand Estimator
# canturk isci.

#NOTES: 
#	1. 
#


use strict;
use warnings;
require "ctime.pl";
#use IO::File::Multi; #multistream output
use IO::Handle; # for autoflush

use Getopt::Long;

my $printString = ""; #String holder for prints
my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst);

#CONFIG CONSTS
my $periodSecs = 4; # will run every 60s

#Global Host / VM inventory
my $numHosts;
my @hostArray;     #maps hostNo -> hostName
my @vmArray;       #maps vmNo -> vmName
my @vmHostMap;     #maps vmNo -> hostNo
my @hostVmList;    #Actually a ~2D array: maps hostNo -> vmNo0, vmNo1,... 
my @hostVmCount;   #maps hostNo -> numVMs
#Global VM Configs
my @vmMemSizes;          #maps vmNo -> memsize [MB]
my @vmVcpus;             #maps vmNo -> num VCPUs
my @vmHdas;              #maps vmNo -> hda images
my @vmMacs;              #maps vmNo -> MAC Address
my @vmTapScripts;        #maps vmNo -> TAP script
my @vmVncs;              #maps vmNo -> VNC no
my @vmMonitors;          #maps vmNo -> Monitor socket
my @vmListenInterfaces;  #maps vmNo -> listening VM TCP interface (Hardcoded to tcp://0:4444)
#Global KVM Threading Map
my @vmMasterThreads;  #maps vmNo -> vm PID (master thread) 
my @vmVcpuThreads;    #2D array: maps vmNo -> TID1, TID2,..., TID<num VCPUs>

#Global vars for SchedStats States
#Master Thread states for each [VM]
my @prev_MasterThread_sum_exec_runtime;
my @prev_MasterThread_wait_sum;
my @prev_MasterThread_iowait_sum;
my @prev_MasterThread_timeSec;
#VCPU Thread states for each [VM][VCPU]
my @prev_VcpuThread_sum_exec_runtime; #2D Array [VM][VCPU]
my @prev_VcpuThread_wait_sum; #2D Array [VM][VCPU]
my @prev_VcpuThread_iowait_sum; #2D Array [VM][VCPU]
my @prev_VcpuThread_timeSec; #1D array [VM] Use the same timestamp for all VCPUs, no need to be further ambitious

#Global VM CPU Stats
my @vmCpuUsagePercentLatest; # Reported % CPU USAGE 
my @vmMemUsagePercentLatest;
my @vmCpuEstimatedDemand2PercentLatest; # Estimated CPU Demand2 (%) [(used+system)/(used+system+wait)] #UPDATE: Ditched CPU System from Estimated demand!
#GLOBAL MASTER THREAD CPU STATS:
my @masterThreadUsedPercent;  #Maps [$vmNo] -> USED[%]
my @masterThreadReadyPercent; #Maps [$vmNo] -> READY[%]
my @masterThreadEstDemand2;   #Maps [$vmNo] -> EST_DEMAND2[%]
#GLOBAL VCPU THREAD CPU STATS:
my @vcpuThreadUsedPercent;    #2D Array: Maps [$vmNo][$VCPU] -> USED[%]
my @vcpuThreadReadyPercent;   #2D Array: Maps [$vmNo][$VCPU] -> READY[%]
my @vcpuThreadEstDemand2;     #2D Array: Maps [$vmNo][$VCPU] -> EST_DEMAND2[%]

#Global Host CPU Stats
my @hostCapacityPercent; # This is a simple sol-n for now. Each host is 2 pcpu so i am saying 200%. This is capacity if host was on.
#Global vars for GetHostStats
my $prevValtx = 0;
my $prevValrx = 0;
my $prevTimetx = 0;
my $prevTimerx = 0;


my @hostCapacityPercentCurr; # This is current capacity. 0 if host OFF.
my @hostVmsCpuUsagePercentLatest; # This is sum of VMs' usage on the host
my @hostAllCpuUsagePercentLatest; # This is the usage seen from host, including all processes.
my @hostVmsCpuEstimatedDemand2PercentLatest; # Estimated CPU Demand2 (%) [(used+system)/(used+system+wait)] #UPDATE: Ditched CPU System from Estimated demand!

&main();

sub main 
{
  my $logFileName = "";
  my $i; 
  
  $logFileName = PrepLogFileName();
  open(LOGFILE, ">$logFileName") or die "Could not open $logFileName for write!\n";
  autoflush LOGFILE 1;
  $printString = sprintf("Writing Log File: $logFileName \n");
  printToStdout($printString);
  $printString = sprintf("*** Started Log: $mon $mday $year $hour:$min:$sec\n\n");
  printToLog($printString);

  $printString = sprintf("\nCONFIGURABLES: \n\n");
  printToLog($printString);
  $printString = sprintf("Invocation period configured for: %ds \n", $periodSecs);  
  printToLog($printString);
  
  #For the simple stats poller we only poll the current host:
  @hostArray=("currHost"); 
  $numHosts = $#hostArray+1;
  GetHostCapacities(); # @hostCapacityPercent only updated here, during init.
  
  BuildInventory();  
  PrintInventory();
  


  for ($i = 0; $i <= $#vmArray; $i++) {
    GetVmConfig($i);
  }
  
  PrintVmConfigs();
  InitSchedStatStates();


  while(1)
  {
    $printString = sprintf("\n\n\n############# BEGIN #############: \n");
    printToStdoutAndLog($printString);
    
    BuildInventory();  
    PrintInventory();
    for ($i = 0; $i <= $#vmArray; $i++) {
      GetVmConfig($i);
    }
    GetVmThreadIds();
    for ($i = 0; $i <= $#vmArray; $i++) {
      GetVmStats($i);      
    }
    for ($i = 0; $i <= $#hostArray; $i++) {
      GetHostStats($i);
    }  
    
    #STATS REPORTING AND MASSAGING
    ComputeAllCpuStats();
    
    sleep($periodSecs);
  } #EO INFINITE WHILE LOOP

  close(LOGFILE);
  
}  
  
  
  
  
# Get the % capacity for each host [ASSUMES ALL HOSTS ON! As initial condition]
# Currently like a placeholder, returns 200% for each host as each have 2PCPUs
# TODO: Has to call each host to get actual capacity
# depends on BuildInventory to create the @hostArray
sub GetHostCapacities 
{
	my $hostNo;
	for ($hostNo = 0; $hostNo <= $#hostArray; $hostNo++) {
	  $hostCapacityPercent[$hostNo] = 200.0;
	}
}


# Build Host / VM inventory from the selected hosts
sub BuildInventory 
{
	my @vmEntitiesOnHost;
	my $hostNo;
	my $vmNo;
	my $currentHostVmCount;
	my @currentHostVmList; # 1-D array to dyn-ly construct the rows of 2-D $hostVmList array 
	
	$vmNo = 0;
	@vmArray = ();
	@vmHostMap = ();
	
	my $line;
	my @fields;
	my $i;
	for ($hostNo = 0; $hostNo <= $#hostArray; $hostNo++) {
		my $vmString = "";
		open(kvmCommands, " ps aux | grep kvm |")  or die "Could not open kvmCommands: $!\n";
		while ($line = <kvmCommands>) {
			if ($line =~ /\.*(qemu-kvm)\.*/) {
				@fields = split(/\s+/, $line);
				for ($i = 0; $i <= $#fields; $i++) {
					if ($fields[$i] eq "-name") {
						#printf STDOUT ("$line : $fields[$i] $fields[$i+1]\n");
						$vmString = $vmString . "$fields[$i+1] " ;
						#printf STDOUT ("$vmString \n");
					}
				}
			}
                }
		@vmEntitiesOnHost = split(/\s+/, $vmString);
		foreach (@vmEntitiesOnHost) {
			$vmArray[$vmNo] = $_;
			$vmHostMap[$vmNo] = $hostNo;
			$vmNo++;
		}
	}
	if ($vmNo == 0) {
		printf STDERR ("\nThere are no VMs on Host!\n");
	}
	# Also create a reverse map of host -> VMs, VM counts for each host
	@hostVmList = ();
	@hostVmCount = ();
	for ($hostNo = 0; $hostNo <= $#hostArray; $hostNo++) {
		$currentHostVmCount = 0;
		@currentHostVmList = (); #empty the array
		for ($vmNo = 0; $vmNo <= $#vmArray; $vmNo++) {
			if ($hostNo == $vmHostMap[$vmNo]) {
				$currentHostVmList[$currentHostVmCount] = $vmNo;
				$currentHostVmCount++
			}
		}
		#copy the current array to the current row of the te 2D $hostVmList array vie the array constructor
		$hostVmList[$hostNo] = [ @currentHostVmList ]; 
		$hostVmCount[$hostNo] = $currentHostVmCount;
	}
}

# Print found inventory
sub PrintInventory 
{
	my $hostNo; my $vmNo;
	
	$printString = sprintf("\nINVENTORY: \n\n");
	printToStdoutAndLog($printString);
	for ($hostNo = 0; $hostNo <= $#hostArray; $hostNo++) {
		my $vmString = "";
		for ($vmNo = 0; $vmNo < $hostVmCount[$hostNo]; $vmNo++) {
			if ($vmNo > 0){ $vmString = $vmString . " | "; }
			$vmString = $vmString . $vmArray[($hostVmList[$hostNo][$vmNo])];
		}
		$printString = sprintf("Host%d: %s VMs: %s\n", $hostNo, $hostArray[$hostNo], $vmString);
		printToStdoutAndLog($printString);
	}
}  
  
# Get VM Commandline and Determine Configs for the VM
# Assumes we already got the inventory info
sub GetVmConfig #pass vmNo as input
{
	my $vmNo = $_[0];
	my $vmHost = $vmHostMap[$vmNo];
	my $vmMemSize = -1; my $vmVcpu = -1; my $vmName = "Unknown"; my $vmHda = "Unknown"; my $vmMac = "Unknown"; 
	my $vmTapScript = "Unknown"; my $vmVnc = "-1"; my $vmMonitor = "Unknown";
	
	my $vmFullCmd; # receive results
	my $vm = $vmArray[$vmNo];
	my $fullCmdLine = "";
	my $line;
	my @fields;
	my $i;	

	# getVmCmdLine VmName:
	#   returns: /usr/bin/qemu-kvm -m 256 -smp 1 -name dslVM1 -hda /daas/S3Virt_VMs/dslVM1.img -net nic,macaddr=54:52:00:1c:35:01 
    #            -net tap,script=/daas/network_scripts/setVmNetwork.sh -vnc :11 -monitor telnet:127.0.0.1:1001,serve
    # With virsh in ResCloud, returns:    
    #/usr/bin/qemu-kvm -S -M pc-0.14 -enable-kvm -m 4096 -smp 4,sockets=4,cores=1,threads=1 -name sahil-vm-37-fedora-16-32bit 
    #-uuid 97ee0b50-3901-f330-efb4-ed17c5c10f5a -nodefconfig -nodefaults 
    #-chardev socket,id=charmonitor,path=/var/lib/libvirt/qemu/sahil-vm-37-fedora-16-32bit.monitor,server,nowait 
    #-mon chardev=charmonitor,id=monitor,mode=control -rtc base=utc 
    #-drive file=/home/canturk/images/sahilf16/vm-37-fedora-16-32bit.img,if=none,id=drive-virtio-disk0,format=raw 
    #-device virtio-blk-pci,bus=pci.0,addr=0x5,drive=drive-virtio-disk0,id=virtio-disk0,bootindex=1 
    #-netdev tap,fd=38,id=hostnet0,vhost=on,vhostfd=39 -device virtio-net-pci,netdev=hostnet0,id=net0,mac=74:70:31:6b:67:45,bus=pci.0,addr=0x3 
    #-chardev pty,id=charserial0 -device isa-serial,chardev=charserial0,id=serial0 -usb -device usb-tablet,id=input0 -vnc 127.0.0.1:4 -vga cirrus 
    #-device intel-hda,id=sound0,bus=pci.0,addr=0x4 -device hda-duplex,id=sound0-codec0,bus=sound0.0,cad=0 -device virtio-balloon-pci,id=balloon0,bus=pci.0,addr=0x6

	open(vmCmdLine, " ps aux | grep kvm | grep $vm |")  or die "Could not open vmCmdLine: $!\n";
	while ($line = <vmCmdLine>) {
		if ($line =~ /\.*(qemu-kvm)\.*/) {
			my $currVmName = "";

			@fields = split(/\s+/, $line);
			# Check back VM Name, to avoid partial matches
			for ($i = 0; $i <= $#fields; $i++) {
				if ($fields[$i] eq "-name") {
					$currVmName = $fields[$i+1];
					last;
				}
			}
			if (!($currVmName eq $vm)) {
				next;
			}
			if ($line =~ /\.*(\/usr\/bin\/qemu-kvm)(.*)/) {
				$fullCmdLine = $1 . $2;
			}
			else {
				$fullCmdLine = $line;
			}
		}
        }
	$vmFullCmd=$fullCmdLine;

	@fields = split(/\s+/, $vmFullCmd);
	for (my $i = 0; $i <= $#fields; $i++) {
		if ($fields[$i] eq "-name") {
			$vmName = $fields[$i+1];
			if (!($vmName eq $vmArray[$vmNo])) {
			  printf STDERR ("Expected VM Name $vmArray[$vmNo], got $vmName\n");
			  exit(-1);
			}
			$i++;
		}
		elsif ($fields[$i] eq "-m") {
			$vmMemSize = $fields[$i+1];
			$i++;
		}
		elsif ($fields[$i] eq "-smp") {
			my @vcpuFields = split(/,/, $fields[$i+1]);
			$vmVcpu = $vcpuFields[0];
			$i++;
		}
		elsif ($fields[$i] eq "-hda") {
			$vmHda = $fields[$i+1];
			$i++;
		}
		# TODO: This is still wrong, only pick the latest one, if multiple drives (don't care for now)
		elsif ($fields[$i] eq "-drive") {
			my @driveFields = split(/[=,\,]/, $fields[$i+1]);
			$vmHda = $driveFields[1];
			$i++;
		}
		elsif ($fields[$i] eq "-vnc") {
			my @vmVncFields = split(/[:,\,]/, $fields[$i+1]);
			$vmVnc = $vmVncFields[1];
			$i++;
		}
		elsif ($fields[$i] eq "-net") {
			my @vmNetFields = split(/=/, $fields[$i+1]);
			if ($vmNetFields[0] eq "nic,macaddr") {
				$vmMac = $vmNetFields[1];
			}
			elsif ($vmNetFields[0] eq "tap,script") {
				$vmTapScript = $vmNetFields[1];
			}
			$i++;
		}
		elsif ($fields[$i] eq "-device") {
			my @vmDevFields = split(/[=,\,]/, $fields[$i+1]);
	        for (my $j = 0; $j <= $#vmDevFields; $j++) {
		        if ($vmDevFields[$j] eq "mac") {
		            $vmMac = $vmDevFields[$j+1];
		        }
		    }
			$i++;
		}
		elsif ($fields[$i] eq "-monitor") {
			$vmMonitor = $fields[$i+1];
			$i++;
		}

	}
	#Update Globals
	$vmMemSizes[$vmNo] = $vmMemSize;	     
	$vmVcpus[$vmNo] = $vmVcpu;	     
	$vmHdas[$vmNo] = $vmHda; 	     
	$vmMacs[$vmNo] = $vmMac; 	     
	$vmTapScripts[$vmNo] = $vmTapScript;	
	$vmVncs[$vmNo] = $vmVnc; 	     
	$vmMonitors[$vmNo] = $vmMonitor;	
	$vmListenInterfaces[$vmNo] = "tcp://0:4444";  #(HARDCODED to tcp://0:4444)
	#$printString = sprintf("\nVM CMD: $vmFullCmd \n");
	#printToStdout($printString);
	#$printString = sprintf("\nVM $vmName: Mem: $vmMemSize, VCPUs: $vmVcpu, HDA: $vmHda, MAC: $vmMac, TAP Script: $vmTapScript, VNC: $vmVnc, Monitor: $vmMonitor\n");
	#printToStdout($printString);
}

# Print VM Configs
sub PrintVmConfigs 
{
	my $vmNo;
	
	$printString = sprintf("\nVM CONFIGS: \n\n");
	printToLog($printString);
	$printString = sprintf("VM Memory VCPU hda MAC TAP_Script VNC Monitor Listener\n");
	printToLog($printString);
	for ($vmNo = 0; $vmNo <= $#vmArray; $vmNo++) {
		$printString = sprintf("%s %5d %5d %s %s %s %5d %s %s\n", 
		                 $vmArray[$vmNo], $vmMemSizes[$vmNo], $vmVcpus[$vmNo], $vmHdas[$vmNo], $vmMacs[$vmNo], 
		                 $vmTapScripts[$vmNo], $vmVncs[$vmNo], $vmMonitors[$vmNo], $vmListenInterfaces[$vmNo]);
		printToLog($printString);
	}
}  

# Initialize Global States for SchedStats
#Assumes we already got the Inventory (vmArray) and VM Configs (VCPUs)
sub InitSchedStatStates 
{
	my $vmNo;
	for ($vmNo = 0; $vmNo <= $#vmArray; $vmNo++) {
		$prev_MasterThread_sum_exec_runtime[$vmNo] = 0.0;
		$prev_MasterThread_wait_sum[$vmNo]         = 0.0;
		$prev_MasterThread_iowait_sum[$vmNo]	   = 0.0;
		$prev_MasterThread_timeSec[$vmNo]          = 0.0;
		for (my $v = 0; $v < $vmVcpus[$vmNo]; $v++) {
			$prev_VcpuThread_sum_exec_runtime[$vmNo][$v] = 0.0;
			$prev_VcpuThread_wait_sum[$vmNo][$v]         = 0.0;
			$prev_VcpuThread_iowait_sum[$vmNo][$v]       = 0.0;
		}
		#Use the same timestamp for all VCPUs:
		$prev_VcpuThread_timeSec[$vmNo]            = 0.0;
	}
}  

#Get the thread ID info for all VMs at once
#Assumes we already got the Inventory (vmArray) and VM Configs (VCPUs)
#Update Global KVM Threading Maps
sub GetVmThreadIds
{
	my $hostNo;
	
	@vmMasterThreads = ();
	@vmVcpuThreads = ();
	
	my $line;
	my @fields;
	my $i;
	my $currPid;
	my $currTid;
	my $currVmName;
	my $vmNo;
	
	my @currVcpu;
	#initialize
	for ($vmNo = 0; $vmNo <= $#vmArray; $vmNo++) {
		$currVcpu[$vmNo]=0;
	}
	
	for ($hostNo = 0; $hostNo <= $#hostArray; $hostNo++) {
		open(kvmThreads, " ps -eL -o pid,tid,cmd | grep qemu |")  or die "Could not open kvmThreads: $!\n";
		#Returns <pid> tid> <cmdline>
		while ($line = <kvmThreads>) {
			chomp($line);
			if ($line =~ /\.*(qemu-kvm)\.*/) {
				$line =~ s/^\s+//; #remove leading s 
				$line =~ s/\s+$//; #remove trailing s 
				#printf " $line \n";

				@fields = split(/\s+/, $line);
				$currPid = $fields[0]; #printf "$currPid\n";
				$currTid = $fields[1]; #printf "$currTid \n";
				for ($i = 0; $i <= $#fields; $i++) {
					#printf "$i: $fields[$i]\n";
					if ($fields[$i] eq "-name") {
						$currVmName = $fields[$i+1] ;
						#printf "currVmName: $currVmName\n";
					}
				}
				# Find the right vmNo from vmName
				for ($vmNo = 0; $vmNo <= $#vmArray; $vmNo++) {
					if ($currVmName eq $vmArray[$vmNo]) {
						last;
					}
				}
				#MY ASSUMPTION:
				# If PID==TID --> Master thread, if PID<TID --> VCPU Thread
				if ($currPid eq $currTid) {
					$vmMasterThreads[$vmNo] = $currPid;
				}
				else {
					$vmVcpuThreads[$vmNo][$currVcpu[$vmNo]] = $currTid;
					#$vmVcpuThreads[$currVcpu[$vmNo]] = $currTid;
					$currVcpu[$vmNo]++;
				}
			}
                }
	}
	
	#Print: 
	for ($vmNo = 0; $vmNo <= $#vmArray; $vmNo++) {
		$printString = sprintf("VM%d: %s, Master PID: %d, VCPU TIDs:", $vmNo, $vmArray[$vmNo], $vmMasterThreads[$vmNo]);
		printToLog($printString);
		for (my $v = 0; $v < $vmVcpus[$vmNo]; $v++) {
			$printString = sprintf(" %d", $vmVcpuThreads[$vmNo][$v]);
			printToLog($printString);
		}
		$printString = sprintf(" \n");
		printToLog($printString);

	}
}

# GetVmStats
# Assumes we already got the inventory & TID info
sub GetVmStats #pass vmNo as input
{
	my $vmNo = $_[0];
	my $vmHost = $vmHostMap[$vmNo];

        my $cpuUsagePercentLatest = 0.0;
        my $memUsagePercentLatest = 0.0;
	my $getVmStats;

	my $vm = $vmArray[$vmNo];
	my $percentCpu = -1;
	my $percentMem = -1;
	my $vmNameIndex = 0;
	my $line;
        my $length = 0;
	my $cpuUsagePerc; my $memUsagePerc;
	
	#Get Master Thread ps Stats:
	open(psInfo, " ps -eL -o tid,pcpu,pmem | grep $vmMasterThreads[$vmNo] |")  or die "Could not open kvmThreads: $!\n";
	#Returns <tid> <pcpu> <pmem>
	while ($line = <psInfo>) {
		chomp($line);
		#printf "$line \n";
		my @fields = split(/\s+/, $line);
		$cpuUsagePerc = $fields[2]; #printf "$vmArray[$vmNo]: $vmMasterThreads[$vmNo] CPU: $cpuUsagePerc\n";
		$memUsagePerc = $fields[3]; #printf "$vmArray[$vmNo]: $vmMasterThreads[$vmNo] Mem: $memUsagePerc\n";
	}
	close(psInfo);
	#Get VCPU Thread ps Stats
	for (my $v = 0; $v < $vmVcpus[$vmNo]; $v++) {
		my $currentTid = $vmVcpuThreads[$vmNo][$v];

		open(psInfo, " ps -eL -o tid,pcpu,pmem | grep $currentTid |")  or die "Could not open kvmThreads: $!\n";
		#Returns <tid> <pcpu> <pmem>
		while ($line = <psInfo>) {
			chomp($line);
			#printf "$line \n";
			my @fields = split(/\s+/, $line);
			$cpuUsagePerc = $fields[2]; #printf "$vmArray[$vmNo]: $currentTid CPU: $cpuUsagePerc\n";
			$memUsagePerc = $fields[3]; #printf "$vmArray[$vmNo]: $currentTid Mem: $memUsagePerc\n";
		}
	}
	close(psInfo);


	my $current_MasterThread_sum_exec_runtime;
	my $current_MasterThread_wait_sum;
	my $current_MasterThread_iowait_sum;
	my $current_MasterThread_timeSec = time();
	#Get Master Thread SchedStats: 
	open(schedStats, " cat /proc/$vmMasterThreads[$vmNo]/sched | grep sum |")  or die "Could not open schedStats: $!\n";
	#Returns in  [ms] accrued times:
	#	se.sum_exec_runtime                :      52485029.308710
	#	se.wait_sum                        :       1078657.808323
	#	se.iowait_sum                      :         14464.193884
	#NEWER VERSIONS RETURN:
	#   se.sum_exec_runtime                :      24213571.609076
 	#   se.statistics.wait_sum             :        498395.928100
 	#   se.statistics.iowait_sum           :          1430.074415
	while ($line = <schedStats>) {
		chomp($line);
		my @fields = split(/\s+/, $line);
		if ($fields[0] eq "se.sum_exec_runtime") {
			$current_MasterThread_sum_exec_runtime = $fields[2]; 
		}
		elsif ($fields[0] eq "se.wait_sum") {
			$current_MasterThread_wait_sum = $fields[2]; 
		}
		elsif ($fields[0] eq "se.iowait_sum") {
			$current_MasterThread_iowait_sum = $fields[2]; 
		}
		elsif ($fields[0] eq "se.statistics.wait_sum") {
			$current_MasterThread_wait_sum = $fields[2]; 
		}
		elsif ($fields[0] eq "se.statistics.iowait_sum") {
			$current_MasterThread_iowait_sum = $fields[2]; 
		}
	}
	close(schedStats);
	#compute deltas
	my $delta_MasterThread_sum_exec_runtime = $current_MasterThread_sum_exec_runtime - $prev_MasterThread_sum_exec_runtime[$vmNo];
	my $delta_MasterThread_wait_sum         = $current_MasterThread_wait_sum         - $prev_MasterThread_wait_sum[$vmNo];
	my $delta_MasterThread_iowait_sum       = $current_MasterThread_iowait_sum       - $prev_MasterThread_iowait_sum[$vmNo];
	my $delta_MasterThread_timeSec          = $current_MasterThread_timeSec          - $prev_MasterThread_timeSec[$vmNo];

	#printf "$vmArray[$vmNo]: $vmMasterThreads[$vmNo] delta_MasterThread_sum_exec_runtime: $delta_MasterThread_sum_exec_runtime\n";
	#printf "$vmArray[$vmNo]: $vmMasterThreads[$vmNo] delta_MasterThread_wait_sum: $delta_MasterThread_wait_sum\n";
	#printf "$vmArray[$vmNo]: $vmMasterThreads[$vmNo] delta_MasterThread_iowait_sum: $delta_MasterThread_iowait_sum\n";
	#printf "$vmArray[$vmNo]: $vmMasterThreads[$vmNo] delta_MasterThread_timeSec: $delta_MasterThread_timeSec\n";

	#update global prev schedStats states:
	$prev_MasterThread_sum_exec_runtime[$vmNo] = $current_MasterThread_sum_exec_runtime;
	$prev_MasterThread_wait_sum[$vmNo]         = $current_MasterThread_wait_sum;	  
	$prev_MasterThread_iowait_sum[$vmNo]	   = $current_MasterThread_iowait_sum;	   
	$prev_MasterThread_timeSec[$vmNo]          = $current_MasterThread_timeSec; 	   

	#FINALLY, UPDATE GLOBAL MASTER THREAD CPU STATS:
	$masterThreadUsedPercent[$vmNo]  = $delta_MasterThread_sum_exec_runtime / ($delta_MasterThread_timeSec*1000.0);
	$masterThreadReadyPercent[$vmNo] = $delta_MasterThread_wait_sum / ($delta_MasterThread_timeSec*1000.0);
	$masterThreadEstDemand2[$vmNo]   = $masterThreadUsedPercent[$vmNo] / (1.0 - $masterThreadReadyPercent[$vmNo]);

	#Get VCPU Thread SchedStats: 
	my $current_VcpuThread_timeSec = time();
	for (my $v = 0; $v < $vmVcpus[$vmNo]; $v++) {
		my $current_VcpuThread_sum_exec_runtime;
		my $current_VcpuThread_wait_sum;
		my $current_VcpuThread_iowait_sum;
		my $currentTid = $vmVcpuThreads[$vmNo][$v];
		open(schedStats, " cat /proc/$currentTid/sched | grep sum |")  or die "Could not open schedStats: $!\n";
		#Returns in  [ms] accrued times:
		#	se.sum_exec_runtime                :      52485029.308710
		#	se.wait_sum                        :       1078657.808323
		#	se.iowait_sum                      :         14464.193884
		#NEWER VERSIONS RETURN:
		#   se.sum_exec_runtime                :      24213571.609076
 		#   se.statistics.wait_sum             :        498395.928100
 		#   se.statistics.iowait_sum           :          1430.074415
		#printf STDOUT ("VM: %s | VCPU %d(%d) \n ", $vmArray[$vmNo], $v, $vmVcpuThreads[$vmNo][$v]);
		while ($line = <schedStats>) {
		    #printf STDOUT ("%s \n", $line);
			chomp($line);
			my @fields = split(/\s+/, $line);
			#printf STDOUT ("%s %s\n", $fields[0], $fields[2]);
			if ($fields[0] eq "se.sum_exec_runtime") {
				$current_VcpuThread_sum_exec_runtime = $fields[2]; 
			}
			elsif ($fields[0] eq "se.wait_sum") {
				$current_VcpuThread_wait_sum = $fields[2]; 
			}
			elsif ($fields[0] eq "se.iowait_sum") {
				$current_VcpuThread_iowait_sum = $fields[2]; 
			}
			elsif ($fields[0] eq "se.statistics.wait_sum") {
				$current_VcpuThread_wait_sum = $fields[2]; 
			}
			elsif ($fields[0] eq "se.statistics.iowait_sum") {
				$current_VcpuThread_iowait_sum = $fields[2]; 
			}
		}
		close(schedStats);
		#compute deltas	
		my $delta_VcpuThread_sum_exec_runtime = $current_VcpuThread_sum_exec_runtime - $prev_VcpuThread_sum_exec_runtime[$vmNo][$v];
		my $delta_VcpuThread_wait_sum         = $current_VcpuThread_wait_sum         - $prev_VcpuThread_wait_sum[$vmNo][$v];
		my $delta_VcpuThread_iowait_sum       = $current_VcpuThread_iowait_sum       - $prev_VcpuThread_iowait_sum[$vmNo][$v];
		my $delta_VcpuThread_timeSec          = $current_VcpuThread_timeSec          - $prev_VcpuThread_timeSec[$vmNo];

		#printf "$vmArray[$vmNo]: $vmVcpuThreads[$vmNo][$v] delta_VcpuThread_sum_exec_runtime: $delta_VcpuThread_sum_exec_runtime\n";
		#printf "$vmArray[$vmNo]: $vmVcpuThreads[$vmNo][$v] delta_VcpuThread_wait_sum: $delta_VcpuThread_wait_sum\n";
		#printf "$vmArray[$vmNo]: $vmVcpuThreads[$vmNo][$v] delta_VcpuThread_iowait_sum: $delta_VcpuThread_iowait_sum\n";
		#printf "$vmArray[$vmNo]: $vmVcpuThreads[$vmNo][$v] delta_VcpuThread_timeSec: $delta_VcpuThread_timeSec\n";

		#update global prev schedStats states:
		$prev_VcpuThread_sum_exec_runtime[$vmNo][$v] = $current_VcpuThread_sum_exec_runtime;
		$prev_VcpuThread_wait_sum[$vmNo][$v]         = $current_VcpuThread_wait_sum;	  
		$prev_VcpuThread_iowait_sum[$vmNo][$v]	     = $current_VcpuThread_iowait_sum;	   

		#FINALLY, UPDATE GLOBAL VCPU THREAD CPU STATS:
		if ($delta_VcpuThread_timeSec < 0.01) {
		    # Handle div by 0 case:
		    $vcpuThreadUsedPercent[$vmNo][$v]  = -0.01;
		    $vcpuThreadReadyPercent[$vmNo][$v] = -0.01;
		    $vcpuThreadEstDemand2[$vmNo][$v]   = -0.01;
		}
		else {
		    $vcpuThreadUsedPercent[$vmNo][$v]  = $delta_VcpuThread_sum_exec_runtime / ($delta_VcpuThread_timeSec*1000.0);
		    $vcpuThreadReadyPercent[$vmNo][$v] = $delta_VcpuThread_wait_sum / ($delta_VcpuThread_timeSec*1000.0);
		    $vcpuThreadEstDemand2[$vmNo][$v]   = $vcpuThreadUsedPercent[$vmNo][$v] / (1.0 - $vcpuThreadReadyPercent[$vmNo][$v]);
		}
	}
	$prev_VcpuThread_timeSec[$vmNo]              = $current_VcpuThread_timeSec; 	   
	
	$getVmStats = sprintf("percentCpu $percentCpu percentMem $percentMem\n");

	my @fields = split(/\s+/, $getVmStats);
	for (my $i = 0; $i <= $#fields; $i++) {
		if ($fields[$i] eq "percentCpu") {
			$cpuUsagePercentLatest = $fields[$i+1];
		}
		elsif ($fields[$i] eq "percentMem") {
			$memUsagePercentLatest = $fields[$i+1];
		}

	}
        #$printString = sprintf("VM %s stats: percentCpu %.1lf  percentMem %.1lf\n", $vmArray[$vmNo], $percentCpu, $percentMem);
	#printToStdout($printString);
	#copy to global
	$vmCpuUsagePercentLatest[$vmNo]  = $cpuUsagePercentLatest;
	$vmMemUsagePercentLatest[$vmNo]  = $memUsagePercentLatest;
	$vmCpuEstimatedDemand2PercentLatest[$vmNo]  = -1.0; # NOT IMPLEMENTED FOR KVM 
		#100.0 * ( ($cpuUsedMsLatest) / ($cpuUsedMsLatest+$cpuWaitMsLatest) );
        
}

# GetHostStats
sub GetHostStats #pass HostNo as input
{
	my $hostNo = $_[0];

        my $percentCpuFinal = 0;
        my $usedMemMbytes = 0;
        my $rxMbytesPerSec = 0; 
        my $txMbytesPerSec = 0; 
	
	my $getHostStats;
	my $percentCpu = 0;
	my $usedMem = 0;
	my $delbytesrx = 0;
	my $delbytestx = 0;
	my $delrx = 0;
	my $deltx = 0;
	my $delTimerx;
	my $delTimetx;
	my @line = ();

	my $now1 = time();
	if ($now1 != $prevTimerx) {
        	open (netRxDat,"cat /sys/class/net/eth0/statistics/rx_bytes |") || die "Can't read rx_bytes\n";
            	while(<netRxDat>) {
               		chomp;
               		@line = split;
               		$delbytesrx = $line[0] - $prevValrx;
               		$delTimerx = $now1 - $prevTimerx;
               		$delrx = ($delbytesrx/$delTimerx)/1000000;
               		#print "** RX $now1 $prevTimerx $delTimerx $line[0] $prevValrx $delbytesrx $delrx\n";
               		$prevValrx = $line[0];
               		$prevTimerx = $now1;
            	}
                close(netRxDat);
        }
        my $now2 = time();
        if ($now2 != $prevTimetx) {
		open (netTxDat,"cat /sys/class/net/eth0/statistics/tx_bytes |") || die "Can't read tx_bytes\n";
            	while(<netTxDat>) {
               		chomp;
               		@line = split;
               		$delbytestx = $line[0] - $prevValtx;
               		$delTimetx = $now2 - $prevTimetx;
               		$deltx = ($delbytestx/$delTimetx)/1000000;
               		#print "** TX $now2 $prevTimetx $delTimetx $line[0] $prevValtx $delbytestx $deltx\n";
               		$prevValtx = $line[0];
               		$prevTimetx = $now2;
            	}
                close(netTxDat);
        }
	$getHostStats = sprintf("percentCpu %.1lf usedMemMbytes %.1lf rxMbytesPerSec %.3lf txMbytesPerSec %.3lf\n",
	                      $percentCpu, $usedMem, $delrx, $deltx);


	my @fields = split(/\s+/, $getHostStats);
	for (my $i = 0; $i <= $#fields; $i++) {
		if ($fields[$i] eq "percentCpu") {
			$percentCpuFinal = $fields[$i+1];
		}
		elsif ($fields[$i] eq "usedMemMbytes") {
			$usedMemMbytes = $fields[$i+1];
		}
		elsif ($fields[$i] eq "rxMbytesPerSec") {
			$rxMbytesPerSec = $fields[$i+1];
		}
		elsif ($fields[$i] eq "txMbytesPerSec") {
			$txMbytesPerSec = $fields[$i+1];
		}
	}

	# Feed Globals
        $hostAllCpuUsagePercentLatest[$hostNo] = $percentCpuFinal;
}

sub ComputeAllCpuStats 
{
  my $i; my $j;
  
  $printString = sprintf("\nVM CPU Stats: [ <Latest> (<5 Min Average>) ]\n\n");
  printToStdoutAndLog($printString);
  $printString = sprintf("Total VMs: %d\n", $#vmArray+1);
  printToStdoutAndLog($printString);
  $printString = sprintf("%-10s  %2s  %-6s  %5s  %5s  %-8s  %15s  %15s  %15s  %15s\n", 
                  "VM","#V","VCPU","PID","TID","Host","CPU USED(%)","CPU READY(%)","EST. DEMAND2(%)","Mem Usage(%)");
  printToStdoutAndLog($printString);
  for ($i = 0; $i <= $#vmArray; $i++) {
    #First Report Master Thread Stats
    $printString = sprintf("%-10s  %2d  %-6s  %5d  %5d  %-8s  %6.2lf (%6.2lf)  %6.2lf (%6.2lf)  %6.2lf (%6.2lf)  %6.2lf (%6.2lf)\n", 
                    substr($vmArray[$i],0,10), $vmVcpus[$i], "Master", $vmMasterThreads[$i], $vmMasterThreads[$i],
		    substr($hostArray[$vmHostMap[$i]],0,8),
                    $masterThreadUsedPercent[$i]*100.0, 0.0,
                    $masterThreadReadyPercent[$i]*100.0, 0.0,
                    $masterThreadEstDemand2[$i]*100.0, 0.0,
                    $vmMemUsagePercentLatest[$i], 0.0);
    printToStdoutAndLog($printString);
    #Next Report VCPU Thread Stats forEach VCPU
    for (my $v = 0; $v < $vmVcpus[$i]; $v++) {
	$printString = sprintf("%-10s  %2d  %6d  %5d  %5d  %-8s  %6.2lf (%6.2lf)  %6.2lf (%6.2lf)  %6.2lf (%6.2lf)  %6.2lf (%6.2lf)\n", 
                        substr($vmArray[$i],0,10), $vmVcpus[$i], $v, $vmMasterThreads[$i], $vmVcpuThreads[$i][$v],
		        substr($hostArray[$vmHostMap[$i]],0,8),
                        $vcpuThreadUsedPercent[$i][$v]*100.0, 0.0,
                        $vcpuThreadReadyPercent[$i][$v]*100.0, 0.0,
                        $vcpuThreadEstDemand2[$i][$v]*100.0, 0.0,
                        $vmMemUsagePercentLatest[$i], 0.0);
        printToStdoutAndLog($printString);
    }

  }
  
  $printString = sprintf("\nHost CPU Stats: [ <Latest> (<5 Min Average>) ]\n\n");
  printToStdoutAndLog($printString);
  $printString = sprintf("Total Hosts: %d \n", $#hostArray + 1);
  printToStdoutAndLog($printString);
  $printString = sprintf("%-7s  %-15s  %7s  %16s  %16s  %15s  \n",
                 "Host","Name","Cap.(%)","ALL CPU Usage(%)","VMs CPU Usage(%)","Est. Demand2(%)");
  printToStdoutAndLog($printString);
		  
  for ($i = 0; $i <= $#hostArray; $i++) {
    my $vmString = "";
    $hostVmsCpuUsagePercentLatest[$i]  = 0.0;
    $hostVmsCpuEstimatedDemand2PercentLatest[$i]  = 0.0;
    for ($j = 0; $j < $hostVmCount[$i]; $j++) {
        $hostVmsCpuUsagePercentLatest[$i]  += $vmCpuUsagePercentLatest[($hostVmList[$i][$j])];
        $hostVmsCpuEstimatedDemand2PercentLatest[$i]  += $vmCpuEstimatedDemand2PercentLatest[($hostVmList[$i][$j])];
        if ($j > 0){ $vmString = $vmString . " + "; }
        $vmString = $vmString . $vmArray[($hostVmList[$i][$j])];
    }
    $printString = sprintf("Host%-3d  %-15s  %3.0lf/%3.lf  %7.2lf (%6.2lf)  %7.2lf (%6.2lf)  %6.2lf (%6.2lf) <-- %s\n", 
                    $i,substr($hostArray[$i],0,15),
		    $hostCapacityPercent[$i], $hostCapacityPercent[$i],
                    $hostAllCpuUsagePercentLatest[$i], 0.0,
                    $hostVmsCpuUsagePercentLatest[$i], 0.0,
                    $hostVmsCpuEstimatedDemand2PercentLatest[$i], 0.0,
                    substr($vmString,0,30));
    printToStdoutAndLog($printString);
  }

}

 
sub UpdateCurrentDate() #Updates $sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst with now
{
  ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
  $year = $year + 1900;
  $mon++;
  if ($mon < 10) { $mon = "0" . $mon; }
  if ($mday < 10) { $mday = "0" . $mday; }
  if ($hour < 10) { $hour = "0" . $hour; }
  if ($min < 10) { $min = "0" . $min; }
  if ($sec < 10) { $sec = "0" . $sec; }
}

sub PrepLogFileName() #Returns log file name as string
{
  UpdateCurrentDate();
  my $logDate = $year . $mon . $mday . $hour . $min . $sec;
  #my $logDate = ctime(time);
  my $finalLogFileName = "kvmDemandEstimator" . $logDate . ".log";
  
  return $finalLogFileName;
}

#print string to STDOUT
#input: string
sub printToStdout 
{
  my $inString = $_[0];
  
  print STDOUT ($inString);
}

#print string to LOGFILE
#input: string
sub printToLog 
{
  my $inString = $_[0];
  
  print LOGFILE ($inString);
}

#print string to STDOUT and LOGFILE
#input: string
sub printToStdoutAndLog 
{
  my $inString = $_[0];
  
  print STDOUT ($inString);
  print LOGFILE ($inString);
}

  
  
  

