/*
** Jerq I/O control codes
*/

#define	JTYPE		('j'<<8)
#define	JBOOT		(JTYPE|1)
#define	JTERM		(JTYPE|2)
#define	JMPX		(JTYPE|3)
/* ipnx: JMUX is JMPX under its older name -- see PATCHES.md.  Nothing in the
   tarball defines JMUX, and libplot/lib5620/openpl.c uses it. */
#define	JMUX		JMPX
#define	JTIMO		(JTYPE|4)
#define	JWINSIZE	(JTYPE|5)
#define	JTIMOM		(JTYPE|6)
#define	JZOMBOOT	(JTYPE|7)
#define	JEXIT		(JTYPE|8)
#define	JDELETE		(JTYPE|9)
#define	JCHDIR		(JTYPE|10)

/*
** ipnx: THREE IX OPCODES THE TAPE USES AND DEFINES NOWHERE.  These values are
** OURS, not Bell Labs', and that makes this a DEVIATION rather than a
** restoration -- so it is stated here rather than inferred from the numbers.
**
** JTOOB, JLABEL and JPEX appear in exactly three files --
**
**	src/history/ix/src/jerq/mux/mux.c        :469, :583, :592
**	src/history/ix/src/jerq/mux/term/demux.c
**	src/history/ix/src/jerq/32ld/32ld.c
**
** -- and in no header anywhere in the 25,682.  All four surviving jioctl.h lack
** them (blit/include, blit/src/ompx/sys/4.2bsd, src/630/include/sys,
** src/630/3binc/sys), so IX's own copy did not survive.  Same shape as the
** `3cc' cross-compiler family, documented in man9/3cc.9 with no binary and no
** source.
**
** THE FAMILY IS RIGHT EVEN THOUGH THE NUMBERS ARE NOT KNOWABLE.  mux.c:583 is
** `ctlvec[0]=JLABEL' and :592 is `p[0] = JPEX' -- byte slots -- which looks like
** a different namespace until mux.c:232 does `buf[0]=JTIMO' with JTIMO being
** (JTYPE|4).  So mux really does put JTYPE|n through a char, and all three
** belong here.  The surviving headers use 1..10 and DISAGREE about 9 and 10
** (blit: JDELETE/JCHDIR; 630: JAGENT/JTRUN), so the numbering is not even
** universal across terminals and IX's additions cannot be deduced from it.
** 11..13 is simply the first free run.
**
** WHY A GUESS IS ACCEPTABLE HERE AND WOULD NOT BE ELSEWHERE.  A guessed function
** can be an honest stub whose failure the caller is written for -- that is what
** muxix.c's pex() returning -1 is.  A guessed WIRE OPCODE puts wrong bytes on a
** wire.  These cannot, because both paths are dead twice over on this system:
**
**	labels and process exclusion are unused -- SIGLAB appears nowhere in
**	lsys/, so checklabs() is never armed, and V10 has no FIOPX at all;
**
**	and the terminal that would interpret them cannot be built from this
**	tape -- muxterm's makefile names 3cc/3as/3ld/3nm and none of the eight
**	survived.
**
** So the requirement is that mux LINK, not that these work, exactly as for
** unsafe/pex/unpex.  If an IX jioctl.h is ever recovered, replace these three
** and delete this comment.
*/
#define	JTOOB		(JTYPE|11)	/* ipnx: value unknown; see above */
#define	JLABEL		(JTYPE|12)	/* ipnx: value unknown; see above */
#define	JPEX		(JTYPE|13)	/* ipnx: value unknown; see above */

struct winsize
{
	char	bytesx, bytesy;
	short	bitsx, bitsy;
};
