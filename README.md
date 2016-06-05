#VM Demand Estimation

KVM implementation of VM CPU Demand Estimation for a single host. 
Run on your KVM compute as `./kvmDemandEstimator.pl`.

***Purpose:***
Compute the actual resource demand of each VM and each QEMU thread on the host, even under resource contention.

***Background:*** Many, if not all, distributed resource management solutions for VMs,containers, etc. 
rely on understanding what these consumers actually *want*. However, most of the time, especially under 
resource contention they only know what they *get* and use this as a poor proxy for their demand. This 
can lead to pretty bad resource management decisions. For example, for VM consolidation, migration, 
autoscaling, understanding demand is pretty important. While we see majority of solutions think what 
they use is a good estimate. 

This project implements a true demand estimation solution based on underlying hypervisor/OS scheduler 
accounting. Using `schedstats` for KVM accounting. The same algorithm is implementable for VMware via VMware `Perf Manager` counters, and for Xen via its scheduler stats, but not included in this version.

***Dependencies:***

* Linux Scheduler `sched-debug` capability.

