#include	"jplot.h"
#include	<sgtty.h>
#include	<signal.h>
#include	<stdio.h>
#include	"/usr/blit/include/jioctl.h"

float 
	boty = 800.,			/* screen bottom y */
	botx = 0.,			/* screen bottom x */
	oboty = 800.,			/* user's bottom y */
	obotx = 0.,			/* user's bottom x */
	scalex = 1.0,			/* scale factor x */
	scaley = -1.0,			/* scale factor y */
	deltx = 800.,			/* length of screen x */
	delty = -800.			/* length of screen y */
;	

int
	mpx = 0,			/* 0 if standalone, 1 if mpx */
	wantready = 0,			/* 0 if blast ahead, 1 if want READY */
	tojerq = -1,			/* file descriptor to jerq */
	fromjerq = -1,			/* file descriptor from jerq */
	lastx = -1,			/* current position x */
	lasty = -1			/* current position y */
;

struct sgttyb
	cooked				/* cooked tty modes */
;

void
openpl()
{
	struct sgttyb
		raw			/* raw tty modes */
	;

	char 
		*ttyname(),		/* return the tty name if found */
		plotty[40],		/* name buffer for jerq name */
		cmd[100],		/* 68ld cmd to be */
		*tty			/* ttyname return */
	;

	if (fromjerq == -1) {
		fromjerq = open("/dev/tty", 0);

		if ((tty = ttyname(1)) == NULL)
			strcpy(plotty,"/dev/tty");
		else
			strcpy(plotty,tty);


		if (ioctl(1,JMPX,0) != -1) {
			mpx = 1;
			sprintf(cmd,"/usr/blit/bin/68ld %s.m < %s > %s",
				JPLOT, plotty, plotty);
		} else
			sprintf(cmd,"/usr/blit/bin/68ld %s.j < %s > %s",
				JPLOT, plotty, plotty);

		if (!isatty(1))
			tojerq = 1;
		else
			tojerq = open(plotty, 1);

		system(cmd);
	}

	ioctl(tojerq, TIOCGETP, &cooked);
	raw = cooked;
	raw.sg_flags |= RAW;
	raw.sg_flags &= ~ECHO;
	ioctl(tojerq, TIOCSETP, &raw);
	ioctl(fromjerq, TIOCSETP, &raw);

	sleep(2);	/* kludge for data kit */

	start();
}
