#include <math.h>
#include "hp.h"

/* arc -drawing program on a grid.
 * Finds an optimal arc centered at x0,y0 from x1,y1 to
 * x2,y2.  If x2,y2 is not on arc, pick a nearby point.
 * Arc excludes x2,y2.
*/

/*arc	`a`	*/
arc(xx1, yy1, xx2, yy2, xx0, yy0, rr)
double	xx1, yy1, xx2, yy2, xx0, yy0, rr;
{
	short	x1, y1, x2, y2, x0, y0, dir;
	short r1,r2;
	e1->copyx = xx2; 
	e1->copyy = yy2;
	x0 = SCX(xx0);	
	y0 = SCY(yy0);
	x1 = SCX(xx1);	
	y1 = SCY(yy1);
	x2 = SCX(xx2);	
	y2 = SCY(yy2);
	r1 = rr*e1->scaley;
	r2 = rr*e1->scalex;
	r1 = r1<0? -r1: r1;
	r2 = r2<0? -r2: r2;
	if(!r2){
		line(xx0,yy1,xx0,yy2);
		return;
	}
	if(!r1){
		line(xx1,yy0,xx2,yy0);
		return;
	}
	if(rr < 0)
		elarc(x0,y0,r2,r1,x1,y1,x2,y2);
	else
		elarc(x0,y0,r2,r1,x2,y2,x1,y1);
	refresh();
}


