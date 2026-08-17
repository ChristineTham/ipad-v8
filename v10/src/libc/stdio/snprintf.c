/*
 * pANS stdio -- sprintf
 */
#include "iolib.h"
#include <lcc/stdarg.h>	/* ipnx: as vfprintf.c does; see PATCHES.md */
snprintf(buf, len, fmt)
	char *buf;
	int len;
	char *fmt;
{
	int n;
	va_list args;
	char *v;
#ifdef V10
	FILE _strbuf;
	_strbuf._flag = _IOWRT+_IOSTRG;
	_strbuf._ptr = (unsigned char *) buf;
	_strbuf._cnt = len;
#define f &_strbuf
#define sclose(x) buf[n] = 0
#else
	FILE *f=sopenw();
	if(f==NULL)
		return 0;
	setvbuf(f, buf, _IOFBF, len);
#endif
	va_start(args, fmt);
	n=vfprintf(f, fmt, args);
	va_end(args);
	sclose(f);
	return n;
}
