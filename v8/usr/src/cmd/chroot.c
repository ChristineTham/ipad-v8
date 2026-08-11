/*
 * chroot -- run a command with a different root directory.
 *
 *	chroot dir command [args]
 *
 * OURS, not the tape's, and it is here because of an absence rather than a
 * defect: V8 has chroot(2) -- syscall 61, usr/sys/sys/sysent.c, implemented
 * in usr/sys/sys/sys4.c -- and ships no chroot(1) at all. There is no such
 * command on the golden image, no source for one anywhere in usr/src, and no
 * manual page in man1, man2 or man8. The system call has simply never had a
 * command in front of it.
 *
 * Stage 9 is what wants it: the question "can the system we built rebuild
 * itself?" is only answered honestly if the compiler resolves its passes,
 * its libraries and its headers out of the NEW tree and not the one that
 * built it. cc(1) is what makes chroot the right tool rather than a
 * convenience -- `-B' is a runtime option, so the cc installed into DESTDIR
 * still has /lib/ccom compiled in as its default pass directory. Run from
 * outside, that silently means the BUILDING system's passes. Run under
 * chroot, DESTDIR/lib/ccom *is* /lib/ccom, and the same binary that would
 * have cheated now cannot.
 *
 * K&R C throughout: /bin/cc is 1985's and rejects a prototype outright
 * ("expected a NAME in list"). There is no stdlib.h, no unistd.h, and
 * chroot(2) has no declaration to include -- it returns int like everything
 * else that predates the question.
 */
#include <stdio.h>

main(argc, argv)
	int argc;
	char **argv;
{
	if (argc < 3) {
		fprintf(stderr, "usage: chroot directory command [args]\n");
		exit(1);
	}
	if (chroot(argv[1]) < 0) {
		perror(argv[1]);
		exit(1);
	}
	/*
	 * chroot(2) moves the root but leaves the working directory where it
	 * was -- outside the new root. Skipping this leaves a process whose
	 * cwd it can still reach with "..", which is the classic way a chroot
	 * turns out not to be one.
	 */
	if (chdir("/") < 0) {
		perror("chroot: chdir /");
		exit(1);
	}
	execv(argv[2], &argv[2]);
	perror(argv[2]);
	exit(1);
}
