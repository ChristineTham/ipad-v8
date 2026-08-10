#include "jplot.h"

void
arc(xi,yi,x0,y0,x1,y1)
{

	graphic(ARC);
	xysc(xi, yi);
	xysc(x0, y0);
	xysc(x1, y1);
}
