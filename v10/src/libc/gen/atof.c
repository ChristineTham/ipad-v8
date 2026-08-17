#include	<stdlib.h>

double
atof(s)				/* ipnx: K&R, see PATCHES.md */
	char *s;
{
	return(strtod(s, (char **)0));
}
