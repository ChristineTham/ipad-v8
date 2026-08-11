/*
 * ipnxfetch -- what this system is, at a glance.  New in ipnx.
 *
 * neofetch and fastfetch cannot run here and never will: one is bash, the
 * other modern C, and both report through interfaces (sysctl, /sys, DE and
 * GPU probes) that a 1985 kernel has no answer for.  So this is the same
 * idea rewritten against the sources V8 actually has, field for field
 * against what those two print on the host:
 *
 *	user@host   getlogin(3) + /etc/whoami -- V8 keeps the machine's name
 *	            in that file and NOWHERE else: no hostname(1), no
 *	            uname(2), and /etc/rc never sets one.
 *	OS          <ipnx.h>, generated from v8/RELEASE.
 *	Host        the machine we are emulated as.
 *	Kernel      <ipnx.h> banner, plus the mtime of /unix -- the kernel
 *	            running is the one that was built, and its date is real.
 *	Uptime      time(2) minus _bootime read out of the running kernel.
 *	Shell       $SHELL, else the passwd entry.
 *	Terminal    $TERM, which /.profile sets from `tty` -- tty00 is the
 *	            5620, tty07 the wide glass one.
 *	Display     only when TERM says a 5620 is on the other end, since
 *	            that is the only case where the size is knowable.
 *	CPU         the emulated processor.
 *	Memory      _physmem out of the running kernel, in clicks.
 *
 * NOTHING HERE IS INVENTED.  Fields the system cannot answer honestly are
 * omitted rather than guessed -- there is no GPU, no window manager and no
 * desktop environment, and printing "N/A" for them would be noise.  The two
 * numbers that could most easily have been faked, uptime and memory, are
 * read from the kernel's own variables through /dev/kmemr the way ps(1)
 * does, which is why this needs the symbol table in /unix.
 *
 * K&R throughout: /bin/cc is 1985's and rejects a prototype outright.
 */

#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <a.out.h>
#include <pwd.h>
#include <ipnx.h>

#define KERNEL	"/unix"
#define KMEM	"/dev/kmemr"

struct nlist nl[] = {
	{ "_bootime" },
#define X_BOOTIME 0
	{ "_physmem" },
#define X_PHYSMEM 1
	{ "" },
};

char	*getenv();
char	*ctime();
char	*strchr();
long	time();
long	lseek();
struct passwd *getpwuid();

/* Read one long out of the running kernel. Returns 0 on any failure, and
   every caller treats 0 as "cannot say" and prints nothing. */
long
kread(fd, addr)
int fd;
long addr;
{
	long v;

	if (fd < 0 || addr == 0)
		return (0L);
	if (lseek(fd, addr, 0) == -1L)
		return (0L);
	if (read(fd, (char *)&v, sizeof v) != sizeof v)
		return (0L);
	return (v);
}

/* /etc/whoami, minus its newline. V8's login(1) reads the same file. */
char *
nodename()
{
	static char buf[64];
	register char *p;
	FILE *f;

	buf[0] = '\0';
	if ((f = fopen("/etc/whoami", "r")) != NULL) {
		if (fgets(buf, sizeof buf, f) != NULL) {
			if ((p = strchr(buf, '\n')) != NULL)
				*p = '\0';
		}
		fclose(f);
	}
	return (buf[0] ? buf : "ipnx");
}

label(s)
char *s;
{
	printf("%-10s ", s);
}

main(argc, argv)
int argc;
char **argv;
{
	int kfd;
	long boot, now, up, phys;
	long days, hrs, mins;
	char *user, *shell, *term;
	struct passwd *pw;
	struct stat st;

	kfd = -1;
	boot = phys = 0L;
	if (nlist(KERNEL, nl) >= 0)
		kfd = open(KMEM, 0);
	if (kfd >= 0) {
		boot = kread(kfd, nl[X_BOOTIME].n_value);
		phys = kread(kfd, nl[X_PHYSMEM].n_value);
	}

	if ((user = getlogin()) == NULL || *user == '\0') {
		if ((pw = getpwuid(getuid())) != NULL)
			user = pw->pw_name;
		else
			user = "root";
	}

	printf("%s@%s\n", user, nodename());
	printf("------------------------------\n");

	label("OS:");
	printf("ipnx %s Release %s-%s\n",
	       IPNX_SYSNAME, IPNX_RELEASE, IPNX_BRANCH);

	label("Host:");
	printf("VAX-11/780 (emulated)\n");

	label("Kernel:");
	if (stat(KERNEL, &st) == 0) {
		char *c = ctime(&st.st_mtime);
		c[24] = '\0';			/* drop the newline */
		printf("%s, built %s\n", IPNX_BANNER, c);
	} else
		printf("%s\n", IPNX_BANNER);

	if (boot != 0L) {
		now = time((long *)0);
		up = now - boot;
		if (up > 0L) {
			days = up / 86400L;
			hrs  = (up % 86400L) / 3600L;
			mins = (up % 3600L) / 60L;
			label("Uptime:");
			if (days > 0L)
				printf("%ld days, %ld hours, %ld mins\n",
				       days, hrs, mins);
			else if (hrs > 0L)
				printf("%ld hours, %ld mins\n", hrs, mins);
			else
				printf("%ld mins\n", mins);
		}
	}

	if ((shell = getenv("SHELL")) == NULL || *shell == '\0') {
		if ((pw = getpwuid(getuid())) != NULL && *pw->pw_shell)
			shell = pw->pw_shell;
		else
			shell = "/bin/sh";
	}
	label("Shell:");
	printf("%s\n", shell);

	if ((term = getenv("TERM")) != NULL && *term != '\0') {
		label("Terminal:");
		printf("%s\n", term);
		/* The only display whose size we can state as fact. The two
		   screens are the app's fixed presets; a layer under mux is
		   any size at all, so say nothing about layers. */
		if (term[0] == 'd' && term[1] == 'm' && term[2] == 'd') {
			label("Display:");
			printf("DMD 5620, 1 bit\n");
		}
	}

	label("CPU:");
	printf("VAX-11/780 @ 5 MHz (emulated)\n");

	if (phys != 0L) {
		label("Memory:");
		/* physmem is in clicks; V8's own boot banner prints ctob()
		   of it, so this matches the number the machine announced. */
		printf("%ld KiB\n", (phys * 512L) / 1024L);
	}

	exit(0);
}
