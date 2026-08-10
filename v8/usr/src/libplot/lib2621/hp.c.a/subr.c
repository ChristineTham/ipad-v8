#include "hp.h"
pcopy(a,b)
struct penvir *a,*b;
{ 
	b->left = a->left; 
	b->bottom = a->bottom; 
	b->xmin = a->xmin; 
	b->ymin = a->ymin;
	b->scalex = a->scalex; 
	b->scaley = a->scaley;
	b->sidex = a->sidex; 
	b->sidey = a->sidey;
	b->copyx = a->copyx; 
	b->copyy = a->copyy;
	b->grade = a->grade;
	b->quantum = a->quantum;
	b->pmode = a->pmode; 
	b->ppink = a->ppink; 
	b->pbrush = a->pbrush;
}
#define pHEIGHT 22.
#define pWIDTH  22.
int refflag = 1;
int dum;
struct penvir  E[9] = {
{0.,pHEIGHT,0.,0.,3.,-1.,pWIDTH, -pHEIGHT, 0., 0., 1., .5, 1, 0., '-','@','O'},
{0.,pHEIGHT,0.,0.,3.,-1.,pWIDTH, -pHEIGHT, 0., 0., 1., .5, 1, 0.,'-','@','O'},
{0.,pHEIGHT,0.,0.,3.,-1.,pWIDTH,-pHEIGHT,0., 0., 1., .5, 1, 0.,'-', '@', 'O'},
{ 0., 0., 0., 0., 3., 1., pWIDTH, pHEIGHT, 0., 0., 1., .5, 1, 0.,
 '-',  '@',  'O'},
{ 0., 0., 0., 0., 3., 1., pWIDTH, pHEIGHT, 0., 0., 1., .5, 1, 0.,
 '-',  '@',  'O'},
{ 0., 0., 0., 0., 3., 1., pWIDTH, pHEIGHT, 0., 0., 1., .5, 1, 0.,
 '-',  '@',  'O'},
{ 0., 0., 0., 0., 3., 1., pWIDTH, pHEIGHT, 0., 0., 1., .5, 1, 0.,
 '-',  '@',  'O'},
{ 0., 0., 0., 0., 3., 1., pWIDTH, pHEIGHT, 0., 0., 1., .5, 1, 0.,
 '-',  '@',  'O'},
{ 0., 0., 0., 0., 3., 1., pWIDTH, pHEIGHT, 0., 0., 1., .5, 1, 0.,
 '-',  '@',  'O'}
};

struct penvir *e0 = E, *e1 = &E[1], *esave;
#define HUGE 017777777777

struct dist {
	short sx, sy;
	short mx, my;
	long e;
}	*p1,*p2;

static
test(x,y,p)
short x, y;
register struct dist *p;
{
	short dx = x - p->sx;
	short dy = y - p->sy;
	long e = (long)dx*dx+(long)dy*dy;
	if(e <= p->e) {
		p->mx = x;
		p->my = y;
		p->e = e;
	}
}

static
survey(x,y)
short x, y;
{
	test(x,y,p1);
	test(x,y,p2);
}

/* elarc(x0,y0,a,b,x1,y1,x2,y2) draws an arc of the ellipse
 * centered at x0,y0 with half-axes a,b extending counterclockwise
 * from a point near x1,y1 to a point near x2,y2
 * args reversed because ellip1 draws clockwise 
*/
void pt();

elarc(x0,y0,a,b,x2,y2,x1,y1)
short x0, y0, a, b, x2, y2, x1,y1;
{
	struct dist d1,d2;
	short sx1, sy1, sx2, sy2;
	if(a==0)
		return;
	else if(b==0)
		return;
	else {
		sx1 = sgn(d1.sx = x1-x0);
		d1.sx *= sx1;
		sy1 = sgn(d1.sy = y1-y0);
		d1.sy *= sy1;
		sx2 = sgn(d2.sx = x2-x0);
		d2.sx *= sx2;
		sy2 = sgn(d2.sy = y2-y0);
		d2.sy *= sy2;
		d1.e = d2.e = HUGE;
		p1 = &d1;
		p2 = &d2;
		survey(0,b);
		ellip1(0,0,a,b,survey,0,b,a,0);
/*		if(d1.mx!=d2.mx || d1.my!=d2.my)
			pt(d1.mx,d1.my);*/
		ellip1(x0,y0,a,b,pt,
			d1.mx*sx1,d1.my*sy1,d2.mx*sx2,d2.my*sy2);
	}
}
void
pt(x,y)
short x, y;
{
	mvaddch(y,x,e1->ppink);
}
#define labs(x,y) if((x=y)<0) x= -x
#define BIG 077777

/* draw an ellipse centered at x0,y0 with half-axes a,b */

ellipse(x0,y0,a,b)
{
	if(a==0 || b==0)
		line(x0-a,y0-b,x0+a,y0+b);
	else
		ellip1(x0,y0,a,b,pt,0,b,0,b);
}

/* calculate b*b*x*x + a*a*y*y - a*a*b*b avoiding ovfl */

 long
resid(a,b,x,y)
register a,b;
{
	long e = 0;
	long u = b*((long)a*a - (long)x*x);
	long v = (long)a*y*y;
	register short q = u>BIG? HUGE/u: BIG;
	register short r = v>BIG? HUGE/v: BIG;
	while(a || b) {
		if(e>=0 && b) {
			if(q>b) q = b;
			e -= q*u;
			b -= q;
		} else {
			if(r>a) r = a;
			e += r*v;
			a -= r;
		}
	}
	return(e);
}

/* service routine used for both elliptic arcs and ellipses 
 * traces clockwise an ellipse centered at x0,y0 with half-axes
 * a,b starting from the point x1,y1 and ending at x2,y2
 * performing an action at each point
 * x1,y1,x2,y2 are measured relative to center
 * when x1,y1 = x2,y2 the whole ellipse is traced
 * e is the error b^2 x^2 + a^2 y^2 - a^2 b^2
*/

ellip1(x0,y0,a,b,action,x1,y1,x2,y2)
short x0, y0, a, b, x1, y1, x2, y2;
void (*action)();
{
	short z;
	short dx = y1>0? 1: y1<0? -1: x1>0? -1: 1;
	short dy = x1>0? -1: x1<0? 1: y1>0? -1: 1;
	long a2 = (long)a*a;
	long b2 = (long)b*b;
	long e = resid(a,b,x1,y1);
	long dex = b2*(2*dx*x1+1);
	long dey = a2*(2*dy*y1+1);
	long ex, ey, exy;
	a2 *= 2;
	b2 *= 2;
	do {
		labs(ex, e+dex);
		labs(ey, e+dey);
		labs(exy, e+dex+dey);
		if(exy<=ex || ey<ex) {
			y1 += dy;
			e += dey;
			dey += a2;
		}
		if(exy<=ey || ex<ey) {
			x1 += dx;
			e += dex;
			dex += b2;
		}
		(*action)(x0+x1,y0+y1);
		if(x1 == 0) {
			dy = -dy;
			dey = -dey + a2;
		} else if(y1 == 0) {
			for(z=x1; abs(z+=dx)<=a; )
				(*action)(x0+z,y0+y1);
			dx = -dx;
			dex = -dex + b2;
		}
	} while(x1!=x2 || y1!=y2);
}
ptype(){}
idle(){}
