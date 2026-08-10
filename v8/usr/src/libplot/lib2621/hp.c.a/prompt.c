#include "hp.h"
prompt(s, k) 
char	*s; 
int	k; 
{
	mvaddstr(22-k,0,s);
	refresh();
}
