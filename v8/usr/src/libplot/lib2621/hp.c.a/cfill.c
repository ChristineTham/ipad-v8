#include "hp.h"
cfill(s) 
char	*s; 
{
	while (*s != NULL) {
		switch (*s) {
		case 'H': 
			e1->pbrush = *(s + 1); 
			break;
		case 'G': 
			e1->pgap = atoi(s + 1); 
			break;
		case 'A': 
			e1->pslant = atof(s + 1) / RADIANS; 
			break;
		}
		while (*++s != NULL) 
			if (*s == '/') {
				s++;
				break;
			}
	}
}
