#
# ipnx780 -- the VAX-11/780 this project actually has.
#
# OURS, derived from lsys/astro/alice.m and diffed against it in
# v10/src/PATCHES.md.  alice was a real CSRC 11/780; this is the same machine
# reduced to the hardware open-simh's vax780 provides, which is what makes it
# buildable AND bootable rather than only faithful.
#
# WHY A NEW CONFIG RATHER THAN alice.m VERBATIM.  Christine, 2026-08-17: "we
# need to generate a new config that we can build from."  alice describes one
# specific machine at Bell Labs -- two Unibus adapters, two UDA50s at
# deliberately nonstandard addresses, a TU78 tape, a Datakit interface, a DN11
# autodialer.  Compiling that and then failing to boot it teaches nothing about
# V10; compiling a 780 we can run teaches everything.
#
# WHERE THE ADDRESSES COME FROM, AND WHICH SIDE MOVED.  Register and vector
# numbers are compiled into the kernel and are settable in the simulator, so
# where the two disagree it is better to move the SIMULATOR -- that keeps V10's
# own numbers.  The exception is where SIMH simply has no such device, and then
# the device leaves this file.  Measured with `show devices' on
# work/opensimh/BIN/vax780, not assumed.
#
# KEPT FROM alice, unchanged:
#	root regfs ra 0100	UDA50/RA81, 0100 = the BITFS bit, 0 = partition a.
#	ms780 0/1		= SIMH MCTL0, MCTL1
#	ni1010a 0		= SIMH IL, this project's own device model
#				(libsimh/patches/pdp11_il.c).  Present but
#				disabled by default: `set il enable'.
#	ip/udp/tcp/arp		alice already configured the whole stack.
#
# CHANGED, each with a reason:
#	dw780 1 REMOVED		SIMH has ONE Unibus adapter (UBA, nexus 3), so
#				everything alice put on `ub 1' moves to `ub 0'.
#	uda50 1 REMOVED		SIMH's RQ is one controller (RQB/C/D exist but
#				are disabled).  One is enough: unit 0 is the
#				system disk, unit 1 the source disk.
#	uda50 0 reg		0772150, SIMH's default, rather than alice's
#				0772160 -- which alice's own comment calls
#				"annoyingly nonstandard".  This is the one place
#				the CONFIG moved instead of the simulator,
#				because the standard address is also V10's own
#				elsewhere and nothing is lost by using it.
#	ra 2..5 REMOVED		one controller, and we have two disks.
#	swap			one device, ra 01 = unit 0 partition b, which is
#				20480 blocks at offset 10240 in ra_sizes[].
#				alice striped swap across six drives; we have
#				one.
#	tm78/tu78 REMOVED	SIMH's MBA1 carries a TM03, not a TM78, and the
#				tape route is dead here anyway (docs/media-
#				exchange.md: V8's ht driver panics the kernel).
#	mba REMOVED		nothing left on it once the tape goes.
#	dn11, drbit, dk		no counterpart in SIMH's vax780.  dk is Datakit,
#	REMOVED			which is the network V10 lost in 1985.
#	kmc11b KEPT		SIMH has none either, but removing it left ld
#				three symbols short -- see below.
#	dz11 4/5 REMOVED	SIMH's DZ is one controller with 32 lines; one
#				dz11 is what we can drive.
#	dz11 0 vec 0300		SIMH's DZ vector base (C0), not alice's 0320.
#
# netafs AND netbfs ARE NON-ZERO, AND THAT IS THE POINT OF THE 780.
# alice and seki both configure `netafs 0' and `netbfs 0' -- the network
# filesystem types compiled in with ZERO instances -- which is half of why
# "there is no netfs on V10".  The other half was that SIMH's vax750 has no
# Interlan.  Both halves are ours to fix here: we write the config, and the
# 780 has our NI1010.  Weinberger's netfs client has been compiled into every
# V8 kernel since 1985 with nothing to talk to; this is the line that gives
# V10 the same live /n/src share, and retires the courier disk.

root	regfs	ra	0100
swap	ra	01	20480
dump	uddump	0x1001	10240	20480

ms780 0	bus 0	tr 1
ms780 1	bus 0	tr 2

dw780 0	bus 0	tr 3	voff 0x200

#
# The UDA50 at SIMH's standard address: unit 0 is the system disk, unit 1 the
# source disk that tools/v10-srcdisk.sh builds.
#
uda50 0	ub 0	reg 0772150	vec 0154
ra 0	uda50 0	unit 0
ra 1	uda50 0	unit 1

dz11 0	ub 0	reg 0760100	vec 0300
ni1010a 0 ub 0	reg 0764000	vec 0350

#
# KEPT, THOUGH SIMH HAS NO SUCH DEVICE, and the reason is a linker error.
#
# Dropping kmc11b left `ld' three symbols short -- _kmccnt, _kmc, _kmcaddr --
# because something in the kernel references the KMC11B whether or not the
# config declares one.  A configured-but-absent device is exactly what
# autoconfig is for: V10 probes at boot, finds nothing at 0760200, and carries
# on.  alice.m's own line, restored verbatim.
kmc11b 0 ub 0	reg 0760200	vec 0600

kdi	1
drum	0
console	0
starcons 0
mem	0
stdio	0

ttyld	128
nttyld	32
mesgld	256
rmesgld	0
cmcld	0
dkpld	256
cdkpld	0
connld	0
bufld	32

regfs	20
procfs	0
msfs	0
errfs	0
pipefs	0

#
# THE TWO LINES THIS CONFIG EXISTS FOR.  Instances, not merely types.
#
netafs	4
netbfs	4

#
# internet stuff -- alice's own numbers
#
ip	4
udp	16
tcp	96
arp	4
ipld	0
udpld	0
tcpld	0
