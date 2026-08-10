#include <stdio.h>
#include <math.h>
#include "tr.h"
circle(xc, yc, r) 
double	xc, yc, r;
{
	if (r < 0) 
		r = -r;
	move(xc - r, yc);
	printf("\\D'c %du'", NX(2. * r));
}
