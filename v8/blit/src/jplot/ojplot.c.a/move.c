#include "jplot.h"

void
move(xi,yi)
{
	if (xi == lastx && yi == lasty)
		return;

	graphic(MOVE);
	xysc(xi, yi);
}
