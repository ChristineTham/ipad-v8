#include "tr.h"
rvec(x, y) 
double	x, y;
{
	register int	i, kx, ky, ndots;
	double	 zzx, zzy;
	int	sx, sy;
	double	dx, dy, ssx, ssy, tt;
	double	spacesize;
	kx = LX(x); 
	ky = -LY(y);
	if (e1->pmode) {
		if (e1->grade >= 0.9 || (kx && ky) ) 
			printf("\\D'l %du %du'", kx, ky);
		else { 
			if (!ky) 
				printf("\\l'%du'", kx);
			else 
				printf("\\v'-.25m'\\L'%du\\(br'\\v'.25m'", ky);
		}
	} else {	/*dashed line*/
		zzx = SCX(e1->copyx); 
		zzy = SCY(e1->copyy);
		dx = kx; 
		dy = ky; 
		tt = sqrt(dx * dx + dy * dy);
		if (tt < 2*DASHSIZE) { 
			printf("\\D'l %du %du'", kx, ky); 
		}
		else {
			dx /= tt;
			dy /= tt;
			ndots = tt / (2*DASHSIZE) + 1;
			spacesize = (tt - ndots * DASHSIZE) / (ndots - 1);
			sx = DASHSIZE * dx; 
			sy = DASHSIZE * dy;
			ssx = (DASHSIZE + spacesize) * dx; 
			ssy = (DASHSIZE + spacesize) * dy;
			for (i = 0; i < ndots - 1; i++) {
				printf("\n.sp -1\n\\h'%du'\\v'%du'",
				   (int)(zzx), -(int)(zzy));
				printf("\\D'l %du %du'", sx, sy);
				zzx += ssx; 
				zzy -= ssy;
			}
			printf("\n.sp -1\n\\h'%du'\\v'%du'",
			    (int)(SCX(e1->copyx+x)-sx),-(int)(SCY(e1->copyy+y)+sy));
			printf("\\D'l	%du %du'", sx, sy);
		}
	}
	e1->copyx += x;	
	e1->copyy += y;
	move(e1->copyx, e1->copyy);
	RESET
}
