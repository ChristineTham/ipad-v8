/*
 * pANS stdio -- printf
 */
#include "iolib.h"
#include <stdarg.h>	/* ipnx: iolib.h has it only #ifdef sgi */
printf(fmt)		/* ipnx: K&R, see PATCHES.md */
	char *fmt;
{
	int n;
	va_list args;
	va_start(args, fmt);
	n=vfprintf(stdout, fmt, args);
	va_end(args);
	return n;
}
