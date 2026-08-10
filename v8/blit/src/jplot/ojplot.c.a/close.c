#include "jplot.h"
#include <sgtty.h>

void
closepl()
{
	extern struct sgttyb
		cooked			/* cooked tty modes */
	;

	move((int)obotx, (int)(oboty - (36 - oboty)/scaley + oboty));
	finish();
	ioctl(tojerq, TIOCSETP, &cooked);
}
