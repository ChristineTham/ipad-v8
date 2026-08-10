#include "jplot.h"

static int
	opened = 0		/* 0 if in alphanumeric mode, 1 if graphics */
;

static char
	buf[PACKET],		/* storage for a packet of data */
	*p = &buf[0]		/* free position in buf */
;

static void
	flush()			/* output what we have */
;

void
xysc(xi, yi)
{
	int xa, ya;
	xa = (xi-obotx)*scalex+botx;
	ya = (yi-oboty)*scaley+boty;

	graphic((xa&077) | 0300);
	graphic(((xa >> 6) & 017) | ((ya >> 3) & 0160) | 0200);
	graphic(ya&0177 | 0200);

	lastx = xi;
	lasty = yi;
}

void
start()
{
	if (mpx == 0) {
		graphic(ON);
		flush();
		++wantready;
	}
}

void
graphic(c)
char c;
{

	if (opened == 0) {
		++opened;
		graphic(OPEN);
	}

	*p++ = c;
	if (p == &buf[PACKET])
		flush();
}

void
alpha(c)
char c;
{

	if (opened) {
		graphic(CLOSE);
		opened = 0;
	}

	*p++ = c;
	if (p == &buf[PACKET])
		flush();
}

static void
flush()
{
	char c;

	if (wantready)
		do {
			read(fromjerq, &c, 1);
		} while (c != READY);

	write(tojerq, &buf[0], p - &buf[0]);

	p = &buf[0];
}

void
finish()
{
	if (mpx == 0) {
		graphic(OFF);
		flush();
		wantready = 0;
	}

	graphic(CLOSE);
	opened = 0;
	flush();
}


