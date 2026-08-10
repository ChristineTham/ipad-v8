#include "tr.h"
point(xx, yy) 
double	xx, yy;
{
	move(xx, yy);
	rvec(-1., -1.); 
	rvec(2., 2.);
	move(xx, yy);
	rvec(1., -1.); 
	rvec(-2., 2.);
	move(xx, yy);
}
