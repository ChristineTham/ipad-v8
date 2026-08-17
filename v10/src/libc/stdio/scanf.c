/*
 * pANS stdio -- scanf
 */
#include "iolib.h"
#include <lcc/stdarg.h>	/* ipnx: as vfprintf.c does; see PATCHES.md */
scanf(fmt)
	char *fmt;
{
	int n;
	va_list args;
	va_start(args, fmt);
	n=vfscanf(stdin, fmt, args);
	va_end(args);
	return n;
}
