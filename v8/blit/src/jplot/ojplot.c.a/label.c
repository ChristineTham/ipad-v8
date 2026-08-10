#include "jplot.h"

void
label(s)
register char *s;
{

	while (*s)
		alpha(*s++);
}
