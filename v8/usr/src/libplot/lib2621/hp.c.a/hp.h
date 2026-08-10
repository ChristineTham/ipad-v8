#include <curses.h>
#define erasew()	VOID(werase(stdscr))
#undef erase()
#define cmov(y, x)		VOID(wmove(stdscr, y, x))
#undef move()
#define SCX(x) ((dum=((x - e1->xmin)*e1->scalex  + e1->left))<0?dum-.5:dum+.5)
#define SCY(y)  ((dum=((y - e1->ymin)*e1->scaley + e1->bottom))<0?dum-.5:dum+.5)
#define SPOT(A,B,C) mvaddch(B,A,C);
extern int refflag;
extern int dum;
extern struct penvir {
	double left, bottom;
	double xmin, ymin;
	double scalex, scaley;
	double sidex, sidey;
	double copyx, copyy;
	double grade, quantum;
	int pgap;
	double pslant;
	char pmode, ppink, pbrush;
} *e1, *e0, *esave, E[];
#define RADIANS	57.3
struct seg {
	int x, y, X, Y;
	char stat;
};
#define unormy(y)	(double)(e1->ymin+(y-e1->bottom)/e1->scaley)
#define unormx(x)	(double)(e1->xmin+(x-e1->left)/e1->scalex)
