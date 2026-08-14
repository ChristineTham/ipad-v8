/*
 * uname -- print system information.  New in ipnx; Research Unix has none.
 *
 * The Eighth Edition has no uname(1) and no uname(2), and no hostname(1)
 * either.  The machine's name lives in /etc/whoami and nowhere else, /etc/rc
 * never sets one, and the only thing that ever says what system this is is the
 * kernel's boot banner -- which scrolls past once and is then gone.  So there
 * has been no way for a program, or a person, to ask the running system what
 * it is.  There is now.
 *
 * Everything except the node name is compile-time, from <ipnx.h>, which is
 * generated from v8/RELEASE.  That is deliberate: a binary should report the
 * system it was built as part of, not go looking for a file that might disagree
 * with it.
 *
 * K&R C on purpose.  /bin/cc is 1985's and rejects a prototype outright
 * ("expected a NAME in list"); there is no stdlib.h, no unistd.h, and no
 * strtol.  See docs/build-from-source.md.
 */

#include <stdio.h>
#include <ipnx.h>

#define WHOAMI	"/etc/whoami"

char	*nodename();

main(argc, argv)
int argc;
char **argv;
{
	register char *p;
	int sysname, node, release, version, machine, any;
	int i;

	sysname = node = release = version = machine = 0;
	any = 0;

	for (i = 1; i < argc; i++) {
		p = argv[i];
		if (*p != '-') {
			fprintf(stderr, "usage: uname [-amnrsv]\n");
			exit(2);
		}
		while (*++p) switch (*p) {
		case 'a':
			sysname = node = release = version = machine = 1;
			any = 1;
			continue;
		case 's': sysname = 1; any = 1; continue;
		case 'n': node    = 1; any = 1; continue;
		case 'r': release = 1; any = 1; continue;
		case 'v': version = 1; any = 1; continue;
		case 'm': machine = 1; any = 1; continue;
		default:
			fprintf(stderr, "uname: bad flag -%c\n", *p);
			exit(2);
		}
	}

	/* uname with no arguments is uname -s, everywhere it exists */
	if (!any)
		sysname = 1;

	i = 0;
	if (sysname) { printf("%s", "ipnx");            i++; }
	if (node)    { printf(i++ ? " %s" : "%s", nodename()); }
	/* Two arguments, not IPNX_RELEASE "-" IPNX_BRANCH: adjacent string
	   literals are concatenated by ANSI C and by nothing older, and
	   /bin/cc is 1985's -- it stops at `saw STRING'. */
	if (release) { printf(i++ ? " %s-%s" : "%s-%s",
			      IPNX_RELEASE, IPNX_BRANCH); }
	if (version) { printf(i++ ? " %s" : "%s", IPNX_BANNER); }
	if (machine) { printf(i++ ? " %s" : "%s", "vax"); }
	printf("\n");
	exit(0);
}

/*
 * /etc/whoami is a one-line file holding the machine's name.  It is the whole
 * of V8's identity mechanism, and it is frequently absent.
 */
char *
nodename()
{
	static char buf[64];
	register FILE *f;
	register char *p;

	if ((f = fopen(WHOAMI, "r")) == NULL)
		return ("unknown");
	if (fgets(buf, sizeof buf, f) == NULL) {
		fclose(f);
		return ("unknown");
	}
	fclose(f);
	for (p = buf; *p; p++)
		if (*p == '\n') {
			*p = '\0';
			break;
		}
	return (buf[0] ? buf : "unknown");
}
