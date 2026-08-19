/*
 * The three IX interfaces the Tenth Edition does not have.
 *
 * WHY THIS FILE EXISTS.  `src/history/ix' is IX -- Bell Labs' security-enhanced
 * Ninth Edition, with mandatory access control and process labels -- and the only
 * surviving host-side `mux' that speaks the 5620 packet protocol is IX's.  V10's
 * own src/cmd/ has no mux, jerq, blit or 5620 directory at all: on a real V10 the
 * 5620 software arrived as a separate distribution tape installed into
 * /usr/jerq, which the V10 golden does not have.
 *
 * So there is no V10 mux to be faithful to, and this is not a deviation from a
 * V10 artefact.  It is what running IX's mux on V10 costs: its seven objects
 * leave 45 externals for libc and five of those are not in V10's --
 *
 *	labEQ, labLE	compiled from the tape's own ix/src/libc/, UNCHANGED.
 *			Both are pure K&R against <sys/label.h>, which
 *			v10/mk/gen/mux.inc already installs.  They are named in
 *			mux.mk's OBJS, not here.
 *	unsafe		here, mapped onto select(2).
 *	pex, unpex	here, as failing stubs.
 *
 * NONE OF THE THREE BELOW CAN RUN ON V10, and that is the finding rather than a
 * limitation -- see the SIGLAB note under unsafe().  They exist so the program
 * links; the paths that reach them are dead on a kernel with no labels.
 */

#include <sys/types.h>		/* fd_set -- r70 include/sys/types.h */

/*
 * IX's unsafe(2) is a LABELLED select(2): the kernel filters the ready set by
 * the caller's label.  On a machine with no process labels that filtering is the
 * whole difference, so a plain select is the right semantics and not an
 * approximation of it.
 *
 * COMPILING IX's OWN unsafe.c WOULD NOT DO.  It is seven lines --
 *
 *	unsafe(n, r, w) fd_set *r, *w; { return syscall(64+36, n, r, w); }
 *
 * -- and V10's lsys/os/sysent.c:184 is `0, nosys,' with the tape's own comment
 * `64+36 = nosys'.  An empty slot: it would fail rather than do something else's
 * work, but it WOULD fail, and mux's next line is quit("unsafe failed").
 *
 * V10's select takes FOUR arguments -- libc/sys/select.s says `.set select,38'
 * over the comment `select(nfd, rfdset, wfdset, time)', and sysent.c:122 is
 * `4, select'.  mux already calls it that way at mux.c:265, so the four-argument
 * form is the program's own idiom rather than an assumption about V10.
 *
 * THE TIMEOUT IS 0 BECAUSE THIS IS A POLL, and getting that backwards would
 * have busy-spun the program.  lsys/os/sys2.c:242 reads the fourth argument as
 * MILLISECONDS and short-circuits on zero:
 *
 *	rem = (ap->timo+999)/1000 - (time - t);
 *	if (ap->timo == 0 || rem <= 0)
 *		goto done;
 *
 * so 0 means "report what is ready now", NOT "block".  That is exactly what the
 * one call site wants: mux.c:1051 is inside checklabs(), which passes all-ones
 * fd sets to ask which descriptors are readable at this instant and loops
 * `while(nseen)' only while it keeps finding some.  A blocking select there
 * would hang; a zero-timeout one answers.
 *
 * AND ON V10 IT IS NEVER CALLED.  checklabs() runs only when `siglab' is set,
 * and siglab is set only by the SIGLAB handler installed at mux.c:212.  r70's
 * own signal.h:37 defines it -- `SIGLAB 26 / * file label changed; secure unix
 * only (not reset) * /' -- and the annotation is accurate: SIGLAB appears
 * NOWHERE in lsys/, so the V10 kernel never raises it.  NSIG is 32, so the
 * signal(2) call is accepted and simply never fires.  This function therefore
 * has to link and does not have to work -- which is the honest reason it is
 * three lines rather than a labelled select we cannot implement.
 */
unsafe(n, r, w)
	fd_set *r, *w;
{
	return select(n, r, w, 0);
}

/*
 * IX's pex(2)/unpex(2) are process exclusion -- mux calls pex() once, at
 * startup, to ask whether it may hold the terminal exclusively.
 *
 * NOT A SYSCALL, which is why this is a stub and not a mapping: IX's
 * src/libc/pex.c drives an ioctl protocol on FIOPX, and V10's sys/filio.h has
 * no FIOPX at all.  There is nothing on a V10 kernel to map it onto.
 *
 * FAILING IS BEHAVIOUR THE PROGRAM IS WRITTEN FOR, which is what makes a stub
 * honest here rather than a fudge -- mux.c:186:
 *
 *	if(pex(0,-1,0)!=0) { untrusted++; unpex(0,-1); }
 *
 * A non-zero return marks the session untrusted, and a mux running on a kernel
 * with no process exclusion IS untrusted.  So the stub does not defeat a check;
 * it gives the true answer to it.
 */
pex(fd, t, bufp)
	char *bufp;
{
	return -1;
}

unpex(fd, t)
{
	return 0;
}
