#include "hp.h"
move(x, y) 
double	x, y;
{
	short	kx, ky;
	kx = SCX(x); 
	ky = SCY(y);
	cmov(ky,kx);
	e1->copyx = x;	
	e1->copyy = y;
}
