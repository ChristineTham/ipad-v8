#include <stdio.h>
#include <math.h>
#include "tr.h"
pen(s) 
char	*s; 
{
	while (*s != NULL) {
		switch (*s) {
		case 'd':
			if (!(strncmp(s, "dash", 4))) 
				e1->pmode = 0; 
			break;
		case 's':
			if (!(strncmp(s, "solid", 5))) 
				e1->pmode = 1;
			break;
		}
		while (*++s != NULL) 
			if (*s == '/') {
				s++;
				break;
			}
	}
}
