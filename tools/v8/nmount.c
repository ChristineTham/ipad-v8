/*
 * nmount -- mount a host directory over TCP, using the netfs client that has
 * been sitting unused in every Eighth Edition kernel since 1985.  Phase N6.
 *
 *	cc -o nmount nmount.c -lin
 *	./nmount 10.0.2.2 9200 64 /n/macos
 *
 * There is no new file system code here and none was needed. `conf/files`
 * lists `sys/neta.c standard`, so the client is compiled into the kernel
 * already; all a mount needs is a connected stream and one system call. The
 * shipped /usr/net/setup does exactly this over Datakit, which no longer
 * exists; this does it over TCP, which does.
 *
 * The sequence, from usr/src/netfs/setup.c:
 *
 *	fd = callfs(...)		a stream to the server
 *	write(fd, &version, 1)		one byte, on its own
 *	write(fd, &x, sizeof x)		a senda with cmd = NSTART
 *	read(fd, &y, sizeof y)		errno == 0 means accepted
 *	gmount(RMFSTYP, dev, 0, fd, mount)
 *
 * After gmount the kernel owns the connection -- it bumps the stream inode's
 * reference count -- so this program can and does exit immediately. Every
 * subsequent byte on that socket is kernel-generated.
 *
 * TWO THINGS THAT WILL WASTE YOUR AFTERNOON.
 *
 * The tcp device minor must be ODD. usr/sys/inet/tcp_device.c:
 *
 *	if((dev&01) == 0 && (so->so_state&SS_ACTIVE) == 0)
 *		return(0);
 *
 * An even minor may only be opened when its socket is already active, which
 * is the inbound/accept case. Opening /dev/tcp00 to make an outgoing call
 * fails with no diagnostic worth the name. libin's tcp_sock() encodes this as
 * `for(n = 01; n < 100; n += 2)` and never says why.
 *
 * The mount device number must have a ZERO MINOR. sys/neta.c's namount():
 *
 *	if(minor(uap->unqname)) { u.u_error = ENXIO; return; }
 *
 * so the argument is unique-id * 256, exactly as setup.c computes it from
 * /usr/net/friends. The id is meant to be 64...255; nothing enforces it.
 */
#include <sys/types.h>
#include <sys/inet/tcp_user.h>
#include <sys/neta.h>
#include <errno.h>
#include <stdio.h>

#define RMFSTYP 1	/* file system type for the remote file system */

extern int errno;
extern long time();

struct senda x;
struct rcva y;

main(argc, argv)
int argc;
char **argv;
{
	struct tcpuser tu;
	struct tcpreply tr;
	char version, name[32];
	int fd, n, unique, port, dev, silent;
	long faddr;
	char *host, *mnt;

	/*
	 * Unmounting is the same system call with the flag set, and needs
	 * neither a connection nor a mount point: gmount(RMFSTYP, dev, 1, 0, 0).
	 * setup.c calls it "just in case" before every mount, and ignores the
	 * result, because a stale mount of the same dev is the normal state of
	 * affairs after a crash.
	 */
	if (argc == 3 && argv[1][0] == '-' && argv[1][1] == 'u') {
		unique = atoi(argv[2]);
		dev = unique * 256;
		errno = 0;
		gmount(RMFSTYP, dev, 1, 0, 0);
		if (errno != 0 && errno != EINVAL) {
			perror("nmount: unmount");
			exit(1);
		}
		printf("nmount: dev %d unmounted\n", dev);
		exit(0);
	}

	if (argc < 5) {
		fprintf(stderr,
		    "usage: nmount host port unique-id mountpoint [debug]\n");
		fprintf(stderr, "       nmount -u unique-id\n");
		exit(1);
	}
	host = argv[1];
	port = atoi(argv[2]);
	unique = atoi(argv[3]);
	mnt = argv[4];
	silent = argc > 5 ? atoi(argv[5]) : 0;

	if (unique < 1 || unique > 255) {
		fprintf(stderr, "nmount: unique id %d out of range 1..255\n",
		    unique);
		exit(1);
	}
	dev = unique * 256;

	faddr = in_address(host);
	if (faddr == 0) {
		fprintf(stderr, "nmount: bad address %s\n", host);
		exit(1);
	}

	/* Odd minors only -- see the note above. */
	fd = -1;
	for (n = 1; n < 32; n += 2) {
		sprintf(name, "/dev/tcp%02d", n);
		fd = open(name, 2);
		if (fd >= 0)
			break;
	}
	if (fd < 0) {
		fprintf(stderr, "nmount: no free /dev/tcp?? (odd minors)\n");
		perror("open");
		exit(1);
	}
	printf("nmount: using %s\n", name);

	tu.cmd = TCPC_CONNECT;
	tu.src = 0;			/* INADDR_ANY */
	tu.dst = faddr;
	tu.sport = 0;			/* let the stack pick */
	tu.dport = port;
	if (write(fd, (char *)&tu, sizeof tu) != sizeof tu) {
		perror("nmount: tcp connect command");
		exit(1);
	}
	n = read(fd, (char *)&tr, sizeof tr);
	if (n != sizeof tr) {
		fprintf(stderr, "nmount: short tcp reply (%d)\n", n);
		exit(1);
	}
	if (tr.reply != TCPR_OK) {
		fprintf(stderr, "nmount: connect to %s port %d refused\n",
		    host, port);
		exit(1);
	}
	printf("nmount: connected to %s port %d\n", host, port);

	/*
	 * The netfs handshake. Three fields of this senda are overloaded and
	 * carry setup data rather than what their names say: ta is our clock
	 * (the server keeps the difference and applies it to every timestamp
	 * it is later asked to set), uid is the server's debug level, and dev
	 * is the device number this mount will use.
	 */
	for (n = 0; n < sizeof x; n++)
		((char *)&x)[n] = 0;
	version = NETVERSION;
	x.version = NETVERSION;
	x.cmd = NSTART;
	x.trannum = 0;
	x.uid = silent;
	x.dev = dev;
	x.ta = time((long *)0);

	if (write(fd, &version, 1) != 1) {
		perror("nmount: version byte");
		exit(1);
	}
	if (write(fd, (char *)&x, sizeof x) != sizeof x) {
		perror("nmount: NSTART");
		exit(1);
	}
	n = read(fd, (char *)&y, sizeof y);
	if (n != sizeof y) {
		if (y.trannum == -1)
			fprintf(stderr, "nmount: server rejected version %d\n",
			    NETVERSION);
		else
			fprintf(stderr, "nmount: short NSTART reply (%d)\n", n);
		exit(1);
	}
	if (y.errno != 0) {
		errno = y.errno;
		perror("nmount: server refused the mount");
		exit(1);
	}
	printf("nmount: handshake ok, dev %d (id %d)\n", dev, unique);

	if (gmount(RMFSTYP, dev, 0, fd, mnt) != 0) {
		perror("nmount: gmount");
		fprintf(stderr, "nmount: is %s a directory?\n", mnt);
		exit(1);
	}
	close(fd);
	printf("nmount: %s mounted on %s\n", host, mnt);
	exit(0);
}
