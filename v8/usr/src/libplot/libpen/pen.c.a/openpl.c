#include "pen.h"
#define PLOTTER "/dev/hp7580"
extern int tty_ld;
openpl(s)
char *s;
{
	int n, dp;
	struct sgttyb vec;

	dp = open(PLOTTER, 2);
	if (dp < 0) {
		fprintf(stderr, "cannot open plotter %s\n", PLOTTER);
		exit(1);
	}
	if(ioctl(dp, FIOLOOKLD, 0) != tty_ld){
		if(ioctl(dp, FIOPUSHLD, &tty_ld) < 0){
			perror("tty_ld");
			exit(1);
		}
	}
	vec.sg_ispeed = B9600;
	vec.sg_ospeed = B9600;
	vec.sg_flags = CBREAK|CRMOD;
	vec.sg_erase = 0;
	vec.sg_kill = 0;
	ioctl(dp, TIOCSETP, &vec);
	if((pltin = fdopen(dp, "r")) == NULL) {
		fprintf(stderr, "cannot fdopen, pltin");
		exit(1);
	}
	if((pltout = fdopen(dp, "w")) == NULL) {
		fprintf(stderr, "cannot fdopen, pltout");
		exit(1);
	}
/*	system("stty >/dev/hp7580");
*/
	fprintf(pltout, "\033.I;;17:");
	fprintf(pltout, "\033.N;19:");
	fprintf(pltout, "\033.M10;;;10:");
	fprintf(pltout, " IN SP 1 SR .67,1.0\n");
	fprintf(pltout,"OP;\n");
	fflush(pltout);
	e0->p1x = e1->p1x = (float) readInt(pltin);
	e0->p1y = e1->p1y = (float) readInt(pltin);
	e0->p2x = e1->p2x = (float) readInt(pltin);
	e0->p2y = e1->p2y = (float) readInt(pltin);
	DX = e0->p2x - e0->p1x;
	e0->xmax = e1->xmax = DX;
	DY = e0->p2y - e0->p1y;
	e0->ymax = e1->ymax = DY;
	e0->scale = e1->scale = 1.;
	e0->pen = e1->pen = 1;
	e0->charsz = e1->charsz = 1.;
	e0->brush = e1->brush = 1;
	e0->pentype = e1->pentype = 0;
	e0->xmin = e1->xmin = 0;
	e0->ymin = e1->ymin = 0;
	e0->pslant = e1->pslant = 0;
	e0->pgap = e1->pgap = 2.;
	if(*s == 'N'){
		noscale = 0;
		fprintf(pltout,"SC %8.2f,%8.2f %8.2f,%8.2f\n",
			e1->xmin,e1->xmax,e1->ymin,e1->ymax);
	}
	ckerr(1);
}
