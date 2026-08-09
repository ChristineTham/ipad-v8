/*
 * dnsq - ask SIMH's SLiRP DNS forwarder to resolve a name, from inside
 * Research Unix 8th Edition.
 *
 * This is the end-to-end test for the whole B0.5 networking stack. A reply
 * means: V8's streams IP went out over our SIMH NI1010 model, SLiRP NAT'd it
 * to the host resolver, the host asked the real Internet, and the answer came
 * back through all of it and up into a 1985 userland.
 *
 * V8 predates every resolver library, so the query is built by hand. That is
 * no hardship -- a DNS question is a 12-byte header, the name as
 * length-prefixed labels, and two 16-bit fields.
 *
 *	cc -o dnsq dnsq.c -lin
 *	./dnsq tuhs.org [10.0.2.3]
 */
#include <sys/types.h>
#include <sys/inet/udp_user.h>
#include <stdio.h>

#define QRY_ID	0x4b21

/* Encode "tuhs.org" as 4 t u h s 3 o r g 0 */
int
putname(buf, name)
u_char *buf;
char *name;
{
	int n = 0, len, i;
	char *p = name;

	while (*p) {
		for (len = 0; p[len] && p[len] != '.'; len++)
			;
		buf[n++] = len;
		for (i = 0; i < len; i++)
			buf[n++] = p[i];
		p += len;
		if (*p == '.')
			p++;
	}
	buf[n++] = 0;			/* root label */
	return n;
}

timeout()
{
	printf("timed out waiting for a reply\n");
	exit(1);
}

main(argc, argv)
char *argv[];
{
	u_char q[512], r[512];
	char *name, *server;
	u_long dhost;
	int fd, n, i, qd, an, off;

	name = argc > 1 ? argv[1] : "tuhs.org";
	server = argc > 2 ? argv[2] : "10.0.2.3";	/* SLiRP's forwarder */

	dhost = in_address(server);
	if (dhost == 0) {
		fprintf(stderr, "dnsq: bad server address %s\n", server);
		exit(1);
	}

	fd = udp_connect(4711, dhost, 53);
	if (fd < 0) {
		fprintf(stderr, "dnsq: udp_connect failed\n");
		exit(1);
	}

	q[0] = (QRY_ID >> 8) & 0xff;
	q[1] = QRY_ID & 0xff;
	q[2] = 0x01;			/* recursion desired */
	q[3] = 0x00;
	q[4] = 0; q[5] = 1;		/* one question */
	q[6] = 0; q[7] = 0;
	q[8] = 0; q[9] = 0;
	q[10] = 0; q[11] = 0;
	n = 12;
	n += putname(&q[12], name);
	q[n++] = 0; q[n++] = 1;		/* type A */
	q[n++] = 0; q[n++] = 1;		/* class IN */

	printf("asking %s for %s (%d byte query)\n", server, name, n);
	if (write(fd, q, n) != n) {
		perror("write");
		exit(1);
	}

	signal(SIGALRM, timeout);
	alarm(25);
	n = read(fd, r, sizeof(r));
	alarm(0);
	if (n <= 0) {
		printf("no reply (read returned %d)\n", n);
		exit(1);
	}

	qd = (r[4] << 8) | r[5];
	an = (r[6] << 8) | r[7];
	printf("reply: %d bytes, id %02x%02x, rcode %d, %d question(s), %d answer(s)\n",
	       n, r[0], r[1], r[3] & 0xf, qd, an);
	if (an == 0) {
		printf("NO ANSWER RECORDS\n");
		exit(1);
	}

	/* Walk past the echoed question, then over the answer records looking
	   for the first type-A rdata. Names may be compressed (top two bits of
	   a length byte set), which is a two-byte pointer. */
	off = 12;
	for (i = 0; i < qd; i++) {
		while (r[off] != 0) {
			if ((r[off] & 0xc0) == 0xc0) { off++; break; }
			off += r[off] + 1;
		}
		off += 1 + 4;			/* root label + qtype + qclass */
	}
	for (i = 0; i < an; i++) {
		int type, rdlen;

		while (r[off] != 0) {
			if ((r[off] & 0xc0) == 0xc0) { off++; break; }
			off += r[off] + 1;
		}
		off++;
		type = (r[off] << 8) | r[off + 1];
		rdlen = (r[off + 8] << 8) | r[off + 9];
		off += 10;
		if (type == 1 && rdlen == 4) {
			printf("%s has address %d.%d.%d.%d\n", name,
			       r[off] & 0xff, r[off + 1] & 0xff,
			       r[off + 2] & 0xff, r[off + 3] & 0xff);
			printf("THE INTERNET IS REACHABLE FROM V8\n");
			exit(0);
		}
		off += rdlen;
	}
	printf("reply had no A record\n");
	exit(1);
}
