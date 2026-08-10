#define	JPLOT	"/usr/blit/mbin/jplot"

#define	OPEN	033
#define	ARC	00
#define	CONT
#define	MOVE	01
#define	ERASE	02
#define	CLOSE	03
#define	ON	04
#define	OFF	05

#define	PACKET	100
#define	READY	017

int	
	mpx,			/* 0 if standalone, 1 if mpx */
	wantready,		/* 0 if blast ahead, 1 if wait till READY */
	tojerq,			/* fd to jerq tty */
	fromjerq,		/* fd from jerq tty */
	lastx,			/* last x coordinate */
	lasty			/* last y coordinate */
;

void
	alpha(),		/* output a character in alphanumeric mode */
	arc(),			/* draw an arc */
	box(),			/* draw an box */
	circle(),		/* draw a circle */
	closepl(),		/* close the plot */
	cont(),			/* draw to a point */
	dot(),			/* draw a dot */
	erase(),		/* erase the screen */
	finish(),		/* flush buffer, turn off READYs */
	graphic(),		/* output a character in graphics mode */
	label(),		/* output text */
	line(),			/* draw a line */
	linemod(),		/* change line drawing mode */
	move(),			/* move to a point */
	openpl(),		/* open a plot */
	space(),		/* define the user coordinates */
	start(),		/* turn on READYs */
	xysc()			/* scale, pack and output x and y coordinates */
;

float 
	boty,			/* screen bottom y */
	botx,			/* screen bottom x */
	oboty,			/* user's bottom y */
	obotx,			/* user's bottom x */
	scalex,			/* scale factor x */
	scaley,			/* scale factor y */
	deltx,			/* length of screen x */
	delty			/* length of screen y */
;	
