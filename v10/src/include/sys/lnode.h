/*
 * sys/lnode.h -- kernel user shares structure, for the Share scheduler.
 *
 * RECONSTRUCTED BY ipnx.  This file is not in the v10src tarball, and neither
 * is <sys/share.h> or <sys/retlim.h>, although lsys/os/limits.C includes all
 * three -- the kernel half of the Share scheduler's headers is lost with the
 * userland half.  Every declaration below is quoted from the tape's own
 * manual, lnode(5), which prints the header verbatim under the words "The
 * layout as given in the include file is:", and every offset and size is
 * confirmed against Bell Labs' 1989 objects in libc.a.  See
 * v10/src/PATCHES.md for the disassembly.
 */

typedef	short	uid_t;

/*
 * Structure for active shares
 */
struct lnode
{
	uid_t	l_uid;		/* real uid for owner of this node */
	u_short	l_flags;	/* (see below) */
	u_short	l_shares;	/* allocated shares */
	uid_t	l_group;	/* uid for this node's scheduling group */
	float	l_usage;	/* decaying accumulated costs */
	float	l_charge;	/* long term accumulated costs */
};

/*
 * Meaning of bits in l_flags
 */
#define	ACTIVELNODE	001	/* this lnode is on active list */
#define	LASTREF		002	/* set for L_DEADLIM if last reference */
#define	DEADGROUP	004	/* group account is dead */
#define	CHNGDLIMITS	020	/* this lnode's limits have changed */
#define	NOTSHARED	040	/* this lnode gets no share of the m/c */

/*
 * Kernel user share structure
 */
typedef struct kern_lnode *	KL_p;

struct kern_lnode
{
	KL_p	kl_next;	/* next in active list */
	KL_p	kl_prev;	/* prev in active list */
	KL_p	kl_parent;	/* group parent */
	KL_p	kl_gnext;	/* next in parent's group */
	KL_p	kl_ghead;	/* start of this group */
	struct lnode	kl;	/* user parameters (as above) */
	float	kl_gshares;	/* total shares for this group */
	float	kl_eshare;	/* effective share for this group */
	float	kl_norms;	/* share**2 for this lnode */
	float	kl_usage;	/* kl.l_usage / kl_norms */
	float	kl_rate;	/* active process rate for this lnode */
	float	kl_temp;	/* temporary for scheduler */
	float	kl_spare;	/* <spare> */
	u_long	kl_cost;	/* cost accumulating in current period */
	u_long	kl_muse;	/* memory pages used */
	u_short	kl_refcount;	/* processes attached to this lnode */
	u_short	kl_children;	/* lnodes attached to this lnode */
};

/*
 * limits(2) functions.  From the table in limits(2); the starred ones are
 * super-user only.  L_SETLIM's value 3 is confirmed by setlimits.o.
 */
#define	L_MYLIM		0	/* get user's own limits structure */
#define	L_OTHLIM	1	/* get limits associated with uid in lnode */
#define	L_ALLLIM	2	/* all active limits structures are returned */
#define	L_SETLIM	3	/* connect to a new limits structure */
#define	L_DEADLIM	4	/* wait for dead limits belonging to child */
#define	L_CHNGLIM	5	/* change limits fields in existing limits */
#define	L_DEADGROUP	6	/* pick up a dead limits structure */
#define	L_GETCOSTS	7	/* get contents of system shconsts table */
#define	L_SETCOSTS	8	/* set contents of system shconsts table */
#define	L_MYKN		9	/* get user's own kern_lnode structure */
#define	L_OTHKN		10	/* get structure associated with uid */
#define	L_ALLKN		11	/* all active structures are returned */
