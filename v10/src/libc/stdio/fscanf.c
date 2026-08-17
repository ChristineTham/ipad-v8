/*
 * pANS stdio -- fscanf
 */
#include "iolib.h"
#include <lcc/stdarg.h>	/* ipnx: as vfprintf.c does; see PATCHES.md */
fscanf(f, fmt)
	FILE *f;
	char *fmt;
{
	int n;
	va_list args;
	va_start(args, fmt);
	n=vfscanf(f, fmt, args);
	va_end(args);
	return n;
}
