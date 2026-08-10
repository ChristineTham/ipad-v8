#include <stdio.h>
#include <math.h>
#include "tr.h"
#define pHEIGHT 5832.
#define pWIDTH 5832.
#define pSIZE	6.
#define pSMALL	4.
int internal = 0;
double linespace = 13.5;
int CH = 0;
struct penvir  E[9] = {
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0.,  pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"},
{ 0., 0.,0., 0., 1., 1., pWIDTH, pHEIGHT, 
0., 0., pSMALL, 1., pSIZE,0.,32,1, 10, 1,"R"}
};
struct penvir *e0 = E, *e1 = &E[1], *esave;
sscpy(a, b) 
struct penvir *a, *b; 
{ /* copy 'a' onto 'b' */
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
	b->quantum = a->quantum;
	b->grade = a->grade;
	b->ninches = a->ninches;
	b->pmode = a->pmode; 
	b->psize = a->psize; 
	b->pbrush = a->pbrush;
	strcpy(b->pfont, a->pfont);
}
#define TRUNC(A) A>0.? A+0.5: A-0.5
normx(x) 
double	x;
{
	register double	xx;
	xx = SCX(x); 
	return( (int)(xx>0.? xx+.5: xx-.5) );
}
normy(y) 
double	y;
{
	register double	yy;
	yy = SCY(y); 
	return( (int)(yy>0.? yy+.5: yy-.5) );
}
ppause()
{
	printf("\n.bp\n.rs\n.sp 6i\n");
}
ptype(s) 
char	*s;
{
	switch (s[0]) {
	case 'd':
	case '2':
		e0->sidex = e0->sidey = e1->sidex = e1->sidey = 6*D202RES;
		linespace = D202RES/72.;
		return;
	case 'a':
		e0->sidex = e0->sidey = e1->sidex = e1->sidey = 6*APSRES;
		linespace = APSRES/72.;
		return;
	default: 
		fprintf(stderr,"unknown device\n");
		exit(1);
	}
}
idle(){}
