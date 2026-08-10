#include "hp.h"
text(s) 
char	*s; 
{
	register char	*p;
	register short n;
	short	x, y;
	short more, newline, centered, right;
	while(1){
		n = centered = right = more = newline = 0;
	for(p = s; *p != '\0'; p++){
		if (*p == '\\') {
			switch (*(++p)) {
			case 'C': 
				centered++;
				s = p+1;
				continue;
			case 'R':
				right++;
				s = p+1;
				continue;
			case 'L':
				s = p + 1;
				continue;
			case 'n':
				newline++;
				*(p-1) = '\0';
				if(*(p+1) != '\0')more++;
				goto output;
			}
		}
	}
output:
	n = 0;
	if(centered) n = (p - s)/2 ;
	else if(right)n = p - s;
	if(n > 0){
		x = SCX(e1->copyx);
		y = SCY(e1->copyy);
		x -= n;
		cmov(y, x);
	}
	addstr(s);
	if(newline){
		y = SCY(e1->copyy);
		y++;
		e1->copyy = unormy(y);
	}
	move(e1->copyx, e1->copyy);
	if(!more)break;
	s = p+1;
	}
}
