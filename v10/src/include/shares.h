/*
 * shares.h -- format of an /etc/shares record.
 *
 * RECONSTRUCTED BY ipnx.  Not in the v10src tarball, although six libc members
 * include it.  shares(5) names this file and <sys/lnode.h> as the two that
 * define the record, and gives their installed paths as /usr/include/shares.h
 * and /usr/include/sys/lnode.h.  Every constant below is measured out of Bell
 * Labs' own 1989 objects in libc.a -- see v10/src/PATCHES.md.
 */

#include	<sys/lnode.h>

#define	SHAREFILE	"/etc/shares"	/* the data base; shares(5) */
#define	MAXUID		10000		/* largest uid with a shares record */

#ifndef	SYSERROR
#define	SYSERROR	(-1)
#endif

/*
 * One record of /etc/shares, indexed by uid.  20 bytes: the 16-byte lnode
 * followed by the expiry time.
 */
typedef struct
{
	struct lnode	l;		/* the user's shares */
	unsigned long	extime;		/* last active time, 0 if never */
} Share;

extern int		ShareFd;	/* openshares(3) leaves it here */

extern unsigned long	getshares();
extern unsigned long	getshput();
extern int		openshares();
extern void		closeshares();
extern void		sharesfile();
extern int		putshares();
extern int		setlimits();
extern int		limits();
