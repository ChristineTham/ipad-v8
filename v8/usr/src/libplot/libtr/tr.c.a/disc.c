#include <stdio.h>
#include <math.h>
#include "tr.h"
disc(xc, yc, r)
double xc, yc, r;
{
	if(r<0)
		r = -r;
	move(xc-r,yc);
	printf("\\D'c %du'",(int)(SCX(2.*r)+.5));
}
