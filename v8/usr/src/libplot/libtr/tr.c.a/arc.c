#include <stdio.h>
#include "tr.h"
arc(x1, y1, x2, y2, xc, yc, r)
double	x1, x2, y1, y2, xc, yc, r;
{
	register int dx1, dy1, dx2, dy2, ixc, iyc;
	ixc = (int)(SCX(xc));
	iyc = (int)(SCY(yc));
	dx1 = ixc - (int)(SCX(x1));
	dy1 =  iyc -(int)(SCY(y1));
	dx2 = ixc -(int)(SCX(x2));
	dy2 =  iyc - (int)(SCY(y2));
	if(r > 0){
		move(x1,y1);
		dx2 = -dx2;
		dy1 = -dy1;
		printf("\\D'a %du %du %du %du'",
			dx1, dy1, dx2, dy2);
	}
	else {
		move(x2,y2);
		dx1 = -dx1;
		dy2 = -dy2;
		printf("\\D'a %du %du %du %du'",
			dx2, dy2, dx1, dy1);
	}
}
