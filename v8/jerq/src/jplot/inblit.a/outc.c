#include <jerq.h>
#include <layer.h>
#include <font.h>

#include "jcom.h"
#include "jjplot.h"
int tab = 8 * CW;

outc(c, pp, adv)
register Point *pp;
{
	register Fontchar *fp;
	Rectangle r;
	Point p;
	int d;
	Code mode = F_XOR;

	switch(c&0377){
	case '\t':		/* tab modulo 8 */
		d = PtCurrent.x - Drect.origin.x;
		PtCurrent.x = d - (d % tab) + tab + Drect.origin.x;
		break;


	case '\n':		/* linefeed */
		newline();
		break;

	case '\r':		/* carriage return */
		PtCurrent.x = arect.origin.x;
		break;
	case '\b':		/* backspace */
		if(PtCurrent.x > arect.origin.x){
			PtCurrent.x -= CW;
			c = '\01';
			adv = 0;
			mode = F_CLR;
		}
		else break;

	
	default:		/* ordinary char */
		fp = defont.info+c;
		p = *pp;
		r.origin.x = fp->x;
		r.corner.x = (fp+1)->x;
		r.origin.y = fp->top;
		r.corner.y = fp->bottom;
		p.y += fp->top;
		bitblt(defont.bits, r, &display, p, mode);
		if(adv)
			PtCurrent.x += CW;
		break;
	case REQ:
		sendchar(ACK);
		sendchar('\n');
		break;
	case EXIT:
		exit();
	case '\007':		/* bell */
		ringbell();
		break;
	case OPEN:
		graphics();
		break;
	case CLOSE:
		PtCurrent.x = arect.origin.x;
		PtCurrent.y = arect.corner.y - NS;
		return;
	}
	if(PtCurrent.x > arect.corner.x - CW) {
		PtCurrent.x = arect.origin.x;
		newline();
	}
}
