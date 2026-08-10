#include "jplot.h"

void
line(x0,y0,x1,y1)
{
	if (x1 == lastx && y1 == lasty) {
		move(x1, y1);
		cont(x0, y0);
		return;
	}

	move(x0, y0);
	cont(x1, y1);
}

void
cont(x, y)
{
	xysc(x, y);
}
