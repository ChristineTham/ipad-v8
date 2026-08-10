#include "hp.h"
sbox(x0, y0, x1, y1) 
double	x0, y0, x1, y1;
{
	register short i, j;
	short kx0, ky0, kx1, ky1;
	register char *s;
	char str[80];
	kx0 = SCX(x0); 
	kx1 = SCX(x1); 
	ky0 = SCY(y0);
	ky1 = SCY(y1);
	if(ky0 > ky1){
		i = ky0;
		ky0 = ky1;
		ky1 = i;
	}
	i = abs(kx0 - kx1) + 1;
	for(s=str,j=0; j<i;j++)
		*s++ = e1->pbrush;
	*s = '\0';
	s = str;
	for (i = ky0; i <= ky1; i++)
		mvaddstr(i,kx0,s);
	refresh();
}
