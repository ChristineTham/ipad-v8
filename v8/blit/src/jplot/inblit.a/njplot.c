#include <jerq.h>
#include <layer.h>
#include <font.h>

#include "jcom.h"
#include "jjplot.h"

#define	CW	9	/* width of a character */
#define	NS	16	/* height of a character */
#define CURSOR	'\01'

#define	XMARGIN	3	/* inset from border of layer */
#define	YMARGIN	3

Point
	PtCurrent,	/* current position */
	pt(),		/* return character point */
	getpt();		/* return unpaced point from input */

Rectangle
	arect;		/* the aesthetic rectangle in a layer */

Texture t={
0177777, 0177777, 0177777, 0177777,
0177777, 0177777, 0177777, 0177777,
0177777, 0177777, 0177777, 0177777,
0177777, 0177777, 0177777, 0177777};
Texture cherries={
0, 037574, 077776, 017234,
000200, 000500, 003060, 004010,
016030, 037074, 077576, 077576,
077576, 077576, 037074, 016030};
Word *tp;
int
	lineth = 1,
	xdelta,		/* distance along x axis */
	ydelta,		/* distance along y axis */
	delta,		/* min (xdelta, ydelta) */
	pushed = 0;	/* character stored away 0 = no, 1 = yes */
int ingraph = 0;
int curs_vis = 0;
int cflag = 1;

char
	pushc;		/* character stored away */
struct seg mLine[4];

char mcursor[2];
main()
{
	Point p0, p1, p2, p3, p4;
	struct seg  *s, *sp;
	char buf[2];	/* make a string out of one character */
	int r, d, ymin;
	int cir = 0;
	int c;

	mcursor[1] = buf[1] = '\0';
	mcursor[0] = '\01';
	request(SEND |KBD| RCV |  MOUSE);

	arect = Drect;
	arect.origin.x += XMARGIN;
	arect.corner.x -= XMARGIN;
	arect.origin.y += YMARGIN;
	arect.corner.y -= YMARGIN;

	xdelta = arect.corner.x - arect.origin.x;
	ydelta = arect.corner.y - arect.origin.y;
	delta = xdelta > ydelta ? ydelta : xdelta;

	PtCurrent = arect.origin;

	cursswitch(&cherries);
	for(;;) {
		buf[0] = c = getchar();
		cflag = 1;
		switch(c){

		case REQ:
			sendchar(ACK);
			sendchar('\n');
			curs_vis = 0;
			break;
		case EXIT:
			exit();
		case '\007':		/* bell */
			*((char *)(384 * 1024L + 062)) = 2;
			break;

		case '\t':		/* tab modulo 8 */
			PtCurrent.x = (PtCurrent.x | (7 * CW)) + CW;
			break;

		case OPEN:
			ingraph=1;
			while ((c = getchar())  != CLOSE){
				switch(c) {
	
				case HOME:
					PtCurrent.x = arect.origin.x;
					PtCurrent.y = arect.corner.y - NS;
					curs_vis = 1;
					break;
				case ARC:	/* arc's Pcenter, Pstart, Pfinish */
					p0 = getpt();
					p1 = getpt();
					p2 = getpt();
					arc(&display, p0, p1, p2, F_OR);
					PtCurrent = p2;
					break;
				case PAUSE:
				*((char *)(384*1024L+062))=2;
					wait(KBD);
					while(kbdchar() == -1)
						wait(KBD);
					break;
	
				case ERASE:	/* erase screen */
					stipple(arect);
					PtCurrent = arect.origin;
					break;
	
				case MOVE:	/* move to point */
					PtCurrent = getpt();
					break;
				case POINT:
					PtCurrent = getpt();
					point(&display, PtCurrent, F_OR);
					break;
				case LINETH:
					lineth = getchar();
					break;
				case FILL:
					d = getint();
					ymin = getint();
					ymin = muldiv(ymin,delta,800);
					if(d > 4){
					s=(struct seg *)alloc((unsigned)(d*
						sizeof(struct seg)));
					if(s==0)break;
					}
					else s=mLine;
					for(sp=s; sp<s+d; sp++){
						sp->j1 = getpt();
						sp->j2 = getpt();
						sp->stat = 1;
					}
					jjfill(d, s, ymin);
					if(d > 4)
						free(s);
					break;
				case TEXTURE:
					for(tp=&t.bits[0];tp<=&t.bits[15];tp++){
						*tp = getint();
					}
					break;
				case CIRCLE:
					cir++;
				case DISC:
					cir++;
					p0 = getpt();
					r = getint();
					r = muldiv(r,delta,800);
					if(cir == 1)
						disc(&display, p0, r, F_OR);
					else circle(&display, p0, r, F_OR);
					cir = 0;
					break;
				case SBOX:
					p0 = getpt();
					p1 = getpt();
				texture(&display, Rpt(p0, p1), &t, F_STORE);
					PtCurrent = p1;
					break;
	
				case TEXT:
					d = getint();
					PtCurrent.x -= d * CW;
					break;
				case VEC:
					p0 = getpt();
					segment(&display, PtCurrent, p0, F_OR);
					PtCurrent = p0;
					break;
				case PAR:
					p0 = getpt();
					p1 = getpt();
					p2 = getpt();
					parabola(p0, p1, p2);
					break;
				}
			}
			ingraph = 0;
			break;

		case '\b':		/* backspace */
			if(PtCurrent.x > 0)
				PtCurrent.x -= CW;
			break;

		case '\n':		/* linefeed */
			newline();
			cflag = 0;
			break;

		case '\r':		/* carriage return */
			PtCurrent.x = arect.origin.x;
			cflag = 0;
			break;

		default:		/* ordinary char */
			string(&defont, buf, &display, PtCurrent, F_XOR);
			PtCurrent.x += CW;
			break;
		}

		if(curs_vis && cflag)string(&defont,mcursor,&display,PtCurrent,F_OR);
		if(PtCurrent.x > arect.corner.x - CW) {
			PtCurrent.x = arect.origin.x;
			newline();
		}
	}
}

newline()
{
	cursinhibit();
	if(PtCurrent.y >= arect.corner.y - 2 * NS) {
		bitblt(&display, Rpt(Pt(arect.origin.x, arect.origin.y + NS), 
			arect.corner), &display, arect.origin, F_STORE);
		stipple(Rpt(Pt(arect.origin.x, arect.corner.y - NS),
			Drect.corner));
	} else
		PtCurrent.y += NS;
	cursallow();
}

getchar()
{
	register c;

	if (pushed) {
		pushed = 0;
		return(pushc&0377);
	}

	while ((c = rcvchar()) == -1) {
#ifndef MPX
		if(button1() != 0){
			exit(0);
		}
#endif
		if(wait(RCV|MOUSE|KBD) &KBD)
			if(ingraph == 0)
				sendchar(kbdchar()&0177);
	}
	if(curs_vis && cflag)string(&defont,mcursor,&display,PtCurrent,F_XOR);
	return(c&0377);
}

ungetc(c)
char c;
{
	pushc = c;
	++pushed;
}

getint(){
	int d,r;
	r = getchar() & 0377;
	d = getchar();
	return( r | ((d & 0377 )<<8) );
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
