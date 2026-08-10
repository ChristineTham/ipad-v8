#include "jplot.h"

void
space(x0,y0,x1,y1)
{
	obotx = x0;
	oboty = y0;
	scalex = deltx/(x1-x0);
	scaley = delty/(y1-y0);
}
