/*
 * arping - send one ARP request through an Interlan NI1010 and wait for the
 * reply.  Written for the ipnx project to test the SIMH NI1010 model against
 * V8's driver without dragging the whole IP stack into the experiment.
 *
 * This is the smallest thing that exercises both directions of the wire:
 * a frame has to leave the emulated board, reach SIMH's SLiRP NAT, and the
 * reply has to be DMA'd back into a buffer the driver supplied.
 *
 * Writes go to a raw il stream: the driver's ilfixheader() removes the source
 * address from what we hand it, because the board inserts its own.  Reads come
 * back starting at the destination address, so one struct describes both.
 *
 *	cc -o arping arping.c -lin
 *	./arping 10.0.2.2 [my-address]
 */
#include <sys/types.h>
#include <sys/ioctl.h>
#include <sys/ethernet.h>
#include <stdio.h>

struct earp {
	u_char	dhost[6];
	u_char	shost[6];
	u_short	type;
	u_short	hrd;			/* 1 = ethernet */
	u_short	pro;
	u_char	hln;
	u_char	pln;
	u_short	op;			/* 1 = request, 2 = reply */
	u_char	sha[6];
	u_char	spa[4];
	u_char	tha[6];
	u_char	tpa[4];
};

u_char bcast[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

timeout()
{
	printf("no reply\n");
	exit(1);
}

/* V8's userland libc has no bcopy, so store the address in network order
   a byte at a time -- which also makes the htonl call unnecessary. */
put4(dst, v)
u_char *dst;
u_long v;
{
	dst[0] = (v >> 24) & 0xff;
	dst[1] = (v >> 16) & 0xff;
	dst[2] = (v >> 8) & 0xff;
	dst[3] = v & 0xff;
}

pr(what, en)
char *what;
u_char *en;
{
	int i;

	printf("%s ", what);
	for (i = 0; i < 6; i++)
		printf("%02x%s", en[i] & 0xff, i < 5 ? ":" : "\n");
}

main(argc, argv)
char *argv[];
{
	struct earp a, r;
	u_char me[6];
	u_long spa, tpa;
	int fd, i, n, x;
	char *dev;

	if (argc < 2) {
		fprintf(stderr, "usage: arping target [my-addr] [device]\n");
		exit(1);
	}
	tpa = in_address(argv[1]);
	spa = in_address(argc > 2 ? argv[2] : "10.0.2.15");
	dev = argc > 3 ? argv[3] : "/dev/il1";
	if (tpa == 0 || spa == 0) {
		fprintf(stderr, "arping: bad address\n");
		exit(1);
	}

	if ((fd = open(dev, 2)) < 0) {
		perror(dev);
		exit(1);
	}
	x = htons((u_short)ETHERPUP_ARPTYPE);
	if (ioctl(fd, ENIOTYPE, &x) < 0) {
		perror("ENIOTYPE");
		exit(1);
	}
	if (ioctl(fd, ENIOADDR, me) < 0) {
		perror("ENIOADDR");
		exit(1);
	}
	pr("controller address:", me);

	for (i = 0; i < 6; i++) {
		a.dhost[i] = bcast[i];
		a.shost[i] = me[i];		/* driver strips this */
		a.sha[i] = me[i];
		a.tha[i] = 0;
	}
	a.type = htons((u_short)ETHERPUP_ARPTYPE);
	a.hrd = htons((u_short)1);
	a.pro = htons((u_short)ETHERPUP_IPTYPE);
	a.hln = 6;
	a.pln = 4;
	a.op = htons((u_short)1);
	put4(a.spa, spa);
	put4(a.tpa, tpa);

	if (write(fd, &a, sizeof(a)) < 0) {
		perror("write");
		exit(1);
	}
	printf("sent %d byte arp request for %s\n", sizeof(a), argv[1]);

	signal(SIGALRM, timeout);
	alarm(20);
	n = read(fd, &r, sizeof(r));
	alarm(0);
	if (n <= 0) {
		printf("no reply (read returned %d)\n", n);
		exit(1);
	}
	printf("got %d bytes, op %d\n", n, ntohs(r.op));
	pr("sender  hardware address:", r.sha);
	pr("our own hardware address:", me);
	printf("ARP ROUND TRIP OK\n");
	exit(0);
}
