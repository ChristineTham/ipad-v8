#include "tr.h"
move(x, y) 
double	x, y;
{
	printf("\n.sp -1\n\\h'%du'\\v'%du'", (int)SCX(x), -(int)SCY(y));
	e1->copyx = x;	
	e1->copyy = y;
}
