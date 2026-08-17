/*
 * pANS stdio -- vprintf
 */
#include "iolib.h"
#include <lcc/stdarg.h>	/* ipnx: as vfprintf.c does; see PATCHES.md */
vprintf(fmt, args)
	char *fmt;
	va_list args;
{
	return vfprintf(stdout, fmt, args);
}
