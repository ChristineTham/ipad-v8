#include "hp.h"
line(x1, y1, x2, y2) 
double	x1, y1, x2, y2; 
{
	short	kx1, kx2, ky1, ky2;
	int a, b;
	int two_a, two_b, xcrit;
	register eps;
	register dx,dy;
	e1->copyx = x2;	
	e1->copyy = y2;
	kx1 = SCX(x1);	
	ky1 = SCY(y1);
	kx2 = SCX(x2);
	ky2 = SCY(y2);
	a = kx2 - kx1;
	if(a < 0){
		dx = -1;
		a = -a;
	}
	else dx = 1;
	b = ky2 - ky1;
	if(b < 0){
		dy = -1;
		b = -b;
	}
	else dy = 1;
	two_a = 2*a;
	two_b = 2*b;
	xcrit = -b + two_a;
	eps = 0;
	for(;;){
		SPOT(kx1,ky1, e1->ppink);
		if(kx1 == kx2 && ky1 == ky2)
			break;
		if(eps <= xcrit){
			kx1 += dx;
			eps += two_b;
		}
		if(eps >= a || a <= b){
			ky1 += dy;
			eps -= two_a;
		}
	}
	if(refflag)
		refresh();
}
