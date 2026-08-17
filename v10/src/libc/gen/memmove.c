/* Copyright AT&T Bell Laboratories, 1993 */
/* ipnx: r70 has no <stddef.h> and defines size_t nowhere -- PATCHES.md */

extern char *memcpy();

char *
memmove(to, from, n)		/* ipnx: K&R, see PATCHES.md */
	char *to;
	char *from;
	register unsigned int n;
{
	register char *out = to;
	register char *in = from;

	if(n <= 0)	/* works if size_t is signed or not */
		;
	else if(in + n <= out || out + n <= in)
		return(memcpy(to, from, n));	/* hope it's fast*/
	else if(out < in)
		do
			*out++ = *in++;
		while(--n > 0);
	else {
		out += n;
		in += n;
		do
			*--out = *--in;
		while(--n > 0);
	}
	return(to);
}
