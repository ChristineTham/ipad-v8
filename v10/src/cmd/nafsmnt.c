/*
 * nafsmnt -- mount a host directory over TCP with V10's netafs client.
 *
 *	cc -o nafsmnt nafsmnt.c -lin
 *	./nafsmnt 10.0.2.2 9200 /n/host
 *	./nafsmnt -u /n/host
 *
 * ipnx ADDITION, not a patch: see v10/src/PATCHES.md.  Nothing on the tape can
 * do this, and the reason is documented rather than assumed -- netfs/libnetb's
 * `setup' is the shipped mounter and every one of its three transports is
 * Datakit (`ipcopen', `ipcexec', `ipcrexec'), which is the network V10 lost in
 * 1985.  So the tape cannot run as-is and this is the smallest thing that makes
 * it run: a transport it can still have.
 *
 * IT IS A PORT OF THIS PROJECT'S OWN v8/usr/src/cmd/nmount.c, phase N6, and the
 * differences are exactly two system calls:
 *
 *	V8	gmount(RMFSTYP, unique*256, 0, fd, mount)	slot 49
 *	V10	fmount(1, fd, mount, dev)			slot 26
 *
 * THE FOURTH ARGUMENT IS THE DEVICE NUMBER, NOT A FLAG, and the kernel's own
 * parameter name misleads.  `namount(sip, ip, flag, mnt, fstyp)' hands it to
 * nadomount(), which does `pi.i_dev = flag; iget(&pi, flag, ROOTINO)' and builds
 * the root's tag as `(flag<<16)|ROOTINO'.  V8 passed dev as gmount's SECOND
 * argument; V10 moved it to the last.
 *
 *	V8	gmount(RMFSTYP, unique*256, 1, 0, 0)		to unmount
 *	V10	funmount(mount)				slot 50
 *
 * V10 removed gmount -- its slot 49 reads `nosys / was gmount' -- and fmount
 * takes an open FILE DESCRIPTOR, so the CONNECTION is named by the fd while the
 * MOUNT is still named by (fstyp, dev).  V8's zero-minor rule does disappear --
 * sys/neta.c's namount() insisted on it and nadomount() does not -- but the
 * device number itself does not: it is what every request's tag carries.
 *
 * WHY netafs AND NOT netbfs.  V10 carries both clients and ipnx780.m configures
 * four instances of each.  netbfs is the later, portable protocol -- a 24-byte
 * marshalled header, version 2 -- and netafs is V8's, which this project already
 * has a server for: `netfs/' has spoken it since the N track.  The two neta.h
 * headers settle it -- V10's is V8's plus three lines, `NSEARCH 0', `NMKDIR 17'
 * and `NRMDIR 18', with struct senda, struct rcva and the original sixteen
 * opcodes IDENTICAL -- and the filesystem type agrees too: nafs is fstyp 1 in
 * seki's own fstypsw[], which is V8's RMFSTYP.
 *
 * THE TWO THINGS THAT WASTED AN AFTERNOON ON V8 APPLY UNCHANGED, because the
 * inet stack is the same code:
 *
 *   The tcp device minor must be ODD.  tcp_device.c refuses an even minor whose
 *   socket is not already active -- that is the inbound/accept side -- so an
 *   outgoing call on /dev/tcp00 fails with no useful diagnostic.  libin's
 *   tcp_sock() writes `for(n = 01; n < 100; n += 2)' and never says why.
 *
 *   And TCP must have been pushed onto an ip device first (`tcpconfig /dev/ip6
 *   &' on V8).  Without it open() succeeds, the tcpuser write succeeds, and the
 *   connect blocks FOREVER with no diagnostic, because there is nothing
 *   underneath the device.
 *
 * K&R throughout: pcc2 is the compiler and it rejects a prototype outright.
 *
 * ONE INET HEADER, NOT THREE, AND THAT IS NOT TIDINESS.  r70's
 * <sys/inet/tcp.h> has no include guard and <sys/inet/tcp_user.h> includes it
 * itself (`#ifndef KERNEL'), so naming both gives pcc2 the same two typedefs
 * twice -- and the second time round `tcp_port' is already a type name, so
 * `typedef unsigned short tcp_port' reads as three type specifiers combined:
 *
 *	"/usr/include/sys/inet/tcp.h":3:illegal type combination
 *	"/usr/include/sys/inet/tcp.h":5:illegal type combination
 *
 * Two errors pointing at Bell Labs' header and none at the file that caused
 * them.  <sys/inet/in.h> escaped only because its first line happens to be
 * `#ifndef INADDR_ANY'.  The tape's own answer is ipc/libin/tcp_lib.c, which
 * includes <sys/inet/tcp_user.h> and nothing else; <sys/types.h> stays because
 * <sys/neta.h> uses time_t and includes nothing.
 */
#include <sys/types.h>
#include <sys/inet/tcp_user.h>
#include <sys/neta.h>
#include <errno.h>
#include <stdio.h>

#define	NAFS	1	/* netafs, from seki's fstypsw[] -- V8's RMFSTYP */
#define	NAFSDEV	0	/* fmount's 4th arg: this mount's device number.  Safe at
			   zero -- iget() looks up (fstyp, dev, ino) and fstyp 1 is
			   netafs, so it cannot collide with the root disk whatever
			   that disk's dev happens to be. */

extern int errno;
extern long time();
extern char *errstr;		/* libin's own diagnostic, set by tcp_connect */
in_addr in_address();		/* returns a long, so it must be declared */

struct senda x;
struct rcva y;

main(argc, argv)
int argc;
char **argv;
{
	struct tcpuser tu;
	char version, name[32];
	int fd, n, port;
	in_addr faddr;
	char *host, *mnt;

	/*
	 * Unmounting takes the MOUNT POINT and not a device number, which is the
	 * whole shape of the change from gmount to funmount.  V10's umount(8)
	 * takes the mount point for the same reason.
	 */
	if (argc == 3 && argv[1][0] == '-' && argv[1][1] == 'u') {
		errno = 0;
		if (funmount(argv[2]) < 0 && errno != EINVAL) {
			perror("nafsmnt: funmount");
			exit(1);
		}
		printf("nafsmnt: %s unmounted\n", argv[2]);
		exit(0);
	}

	if (argc < 4) {
		fprintf(stderr, "usage: nafsmnt host port mountpoint\n");
		fprintf(stderr, "       nafsmnt -u mountpoint\n");
		exit(1);
	}
	host = argv[1];
	port = atoi(argv[2]);
	mnt = argv[3];

	faddr = in_address(host);
	if (faddr == 0) {
		fprintf(stderr, "nafsmnt: bad address %s\n", host);
		exit(1);
	}

	/*
	 * THE SOCKET AND THE CONNECT ARE THE TAPE'S, NOT OURS.  libin's
	 * tcp_sock() is the odd-minor loop -- `for(n = 01; n < 100; n += 2)',
	 * breaking on any errno but ENXIO -- and tcp_connect() writes the
	 * tcpuser, reads the reply back into the same structure and decodes
	 * every TCPC_ code into errstr.  Hand-rolling either is how the reply
	 * struct got written as V8's in the first place, and Bell Labs already
	 * wrote both for exactly this caller.
	 */
	fd = tcp_sock();
	if (fd < 0) {
		fprintf(stderr, "nafsmnt: no free /dev/tcp?? (odd minors only)\n");
		exit(1);
	}

	/*
	 * THE USERLAND TCP INTERFACE IS NOT THE SAME AS V8'S, even though the
	 * kernel protocol is.  V8's struct tcpuser is
	 *	{ cmd, src, dst, sport, dport }
	 * with a separate `struct tcpreply' carrying `reply'; V10's, in r70's
	 * sys/inet/tcp_user.h, is
	 *	{ int code; tcp_port lport, fport; in_addr laddr, faddr; int param; }
	 * and the REPLY COMES BACK IN THE SAME STRUCTURE with code == TCPC_OK.
	 * There is no tcpreply at all.  Ported straight from V8's names this fails
	 * with eleven `not struct/union member' errors and nothing saying why, so
	 * it is written out here.
	 */
	/*
	 * THE USERLAND TCP INTERFACE IS NOT THE SAME AS V8'S, even though the
	 * kernel protocol is.  V8's struct tcpuser is
	 *	{ cmd, src, dst, sport, dport }
	 * with a separate `struct tcpreply' carrying `reply'; V10's, in r70's
	 * sys/inet/tcp_user.h, is
	 *	{ int code; tcp_port lport, fport; in_addr laddr, faddr; int param; }
	 * and the REPLY COMES BACK IN THE SAME STRUCTURE with code == TCPC_OK.
	 * There is no tcpreply at all.  Ported straight from V8's names this
	 * fails with eleven `not struct/union member' errors and nothing saying
	 * why, so it is written out here.  tcp_connect() sets code itself.
	 */
	tu.laddr = INADDR_ANY;
	tu.faddr = faddr;
	tu.lport = 0;			/* let the stack pick */
	tu.fport = port;
	tu.param = 0;
	errstr = "";
	if (tcp_connect(fd, &tu) < 0) {
		fprintf(stderr, "nafsmnt: connect to %s port %d failed: %s\n",
		    host, port, errstr);
		perror("nafsmnt: tcp_connect");
		exit(1);
	}
	printf("nafsmnt: connected to %s port %d\n", host, port);

	/*
	 * The netfs handshake, in the order netfs/setup.c performs it: one
	 * version byte alone, then a senda whose cmd is NSTART, then the reply.
	 */
	for (n = 0; n < sizeof x; n++)
		((char *)&x)[n] = 0;
	version = NETVERSION;
	x.version = NETVERSION;
	x.cmd = NSTART;
	x.trannum = 0;
	/*
	 * THREE FIELDS ARE OVERLOADED HERE AND CARRY SETUP DATA RATHER THAN WHAT
	 * THEIR NAMES SAY, which docs/netfs-protocol.md records: `ta' is our
	 * clock, and the server keeps the difference and applies it to every
	 * timestamp it is later asked to set; `uid' is the server's debug level;
	 * `dev' is the device number the mount will use.  V8 computed dev from a
	 * unique id because gmount needed one; fmount does not, so it is zero --
	 * the server only ever echoes it back.
	 */
	x.uid = 0;			/* server debug level */
	x.dev = NAFSDEV;		/* and fmount is handed the same number */
	x.ta = time((long *)0);
	if (write(fd, &version, 1) != 1) {
		perror("nafsmnt: version byte");
		exit(1);
	}
	if (write(fd, (char *)&x, sizeof x) != sizeof x) {
		perror("nafsmnt: NSTART");
		exit(1);
	}
	if ((n = read(fd, (char *)&y, sizeof y)) != sizeof y) {
		if (y.trannum == -1)
			fprintf(stderr, "nafsmnt: server rejected version %d\n",
			    NETVERSION);
		else
			fprintf(stderr, "nafsmnt: short NSTART reply (%d)\n", n);
		exit(1);
	}
	if (y.errno != 0) {
		errno = y.errno;
		perror("nafsmnt: server refused the mount");
		exit(1);
	}

	/*
	 * And the mount.  After this the kernel owns the connection -- it bumps
	 * the stream inode's reference count -- so this program exits at once
	 * and every subsequent byte on the socket is kernel-generated.
	 */
	errno = 0;
	if (fmount(NAFS, fd, mnt, NAFSDEV) < 0) {
		perror("nafsmnt: fmount");
		exit(1);
	}
	printf("nafsmnt: mounted on %s\n", mnt);
	exit(0);
}
