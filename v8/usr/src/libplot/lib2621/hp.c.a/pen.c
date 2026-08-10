#include "hp.h"
pen(s) 
char	*s; 
{
	while (*s != NULL) {
		if(*s == 'H'){
			e1->ppink = *(s + 1); 
			break;
		}
		while(*++s != NULL)
			if(*s == '/'){
				s++;
				break;
			}
	}
}
