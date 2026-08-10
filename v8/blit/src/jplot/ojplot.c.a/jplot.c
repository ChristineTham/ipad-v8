#include <jerq.h>
#include <font.h>

#include "jplot.h"

#define	CW	9	/* width of a character */
#define	NS	16	/* height of a character */

#define	XMARGIN	3	/* inset from border of layer */
#define	YMARGIN	3

Point
	PtCurrent,	/* current position */
	pt(),		/* return character point */
	getpt()		/* return unpaced point from input */
;

Rectangle
	arect		/* the aesthetic rectangle in a layer */
;

int
	xdelta,		/* distance along x axis */
	ydelta,		/* distance along y axis */
	delta,		/* min (xdelta, ydelta) */
	pushed = 0,	/* character stored away 0 = no, 1 = yes */
	ready = 0,	/* send out READY every PACKET chararacters */
	incount = 0	/* numbert of characters until we output a READY */
;

char
	pushc		/* character stored away */
;

main()
{
	char
		buf[2]	/* make a string out of one character */
	;
	Point
		p0,	/* temporary points */
		p1,
		p2
	;

	buf[1] = '\0';
#ifndef MPX
	request(SEND | RCV | KBD);
#else
	request (RCV);
#endif

	arect = Drect;
	arect.origin.x += XMARGIN;
	arect.corner.x -= XMARGIN;
	arect.origin.y += YMARGIN;
	arect.corner.y -= YMARGIN;

	xdelta = arect.corner.x - arect.origin.x;
	ydelta = arect.corner.y - arect.origin.y;
	delta = xdelta > ydelta ? ydelta : xdelta;

	PtCurrent = arect.origin;

	for(;;) {
		switch(buf[0] = getchar() & 0177) {

		case '\007':		/* bell */
			*((char *)(384 * 1024L + 062)) = 2;
			break;

		case '\t':		/* tab modulo 8 */
			PtCurrent.x = ((((PtCurrent.x - arect.origin.x) / CW) | 7 )
			    + 1) * CW + arect.origin.x;
			break;

		case OPEN:
			while ((buf[0] = getchar()) != CLOSE)
				switch(buf[0]) {
	
				case ARC:	/* arc's Pcenter, Pstart, Pfinish */
					p0 = getpt();
					p1 = getpt();
					p2 = getpt();
					arc(&display, p0, p1, p2, F_OR);
					PtCurrent = p2;
					break;
	
				case ERASE:	/* erase screen */
					stipple(arect);
					PtCurrent = arect.origin;
					break;
	
				case MOVE:	/* move to point */
					PtCurrent = getpt();
					break;
	
#ifndef MPX
				case OFF:	/* stop sending READYs */
					ready = 0;
					break;

				case ON:	/* start sending READYs */
					incount = PACKET;
					++ready;
					sendchar(READY);
					break;

#endif
				default:	/* continue to P */
					ungetc(buf[0]);
					segment(&display, PtCurrent, p0 = getpt(), F_OR);
					PtCurrent = p0;
					break;
				}
			break;

		case '\b':		/* backspace */
			if(PtCurrent.x > 0)
				PtCurrent.x -= CW;
			break;

		case '\n':		/* linefeed */
			newline();

		case '\r':		/* carriage return */
			PtCurrent.x = arect.origin.x;
			break;

		default:		/* ordinary char */
			string(&defont, buf, &display, PtCurrent, F_STORE);
			PtCurrent.x += CW;
			break;
		}

		if(PtCurrent.x > arect.corner.x - CW) {
			PtCurrent.x = arect.origin.x;
			newline();
		}
	}
}

newline()
{
	if(PtCurrent.y >= arect.corner.y - 2 * NS) {
		bitblt(&display, Rpt(Pt(arect.origin.x, arect.origin.y + NS), 
			arect.corner), &display, arect.origin, F_STORE);
		stipple(Rpt(Pt(arect.origin.x, arect.corner.y - NS),
			Drect.corner));
	} else
		PtCurrent.y += NS;
}

getchar()
{
	register c;

	if (pushed) {
		pushed = 0;
		return(pushc);
	}

	while ((c = rcvchar()) == -1) {
#ifndef MPX
		if ((c = kbdchar()) != -1)
			sendchar(c&0177);
#else
		wait(RCV);
#endif
	}
#ifndef MPX
	if (ready && --incount == 0) {
		sendchar(READY);
		incount = PACKET;
	}
#endif
	return(c);
}

ungetc(c)
char c;
{
	pushc = c;
	++pushed;
}

Point
getpt()
{
	Point	p;
	char	c;

	p.x = getchar()&077;
	c = getchar();
	p.x |= (c&017) << 6;
	p.y = getchar()& 0177;
	p.y |= (c&0160) << 3;

	p.x = muldiv(p.x, delta, 800);
	p.x += arect.origin.x;
	p.y = muldiv(p.y, delta, 800);
	p.y += arect.origin.y;

	return (p);
}

#ifndef MPX
stipple(r)
Rectangle r;
{
	rectf(&display, r, F_CLR);
}
#endif
