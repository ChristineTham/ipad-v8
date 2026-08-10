CFLAGS = -O
LDFLAGS = -s

INS = cp
LIBNAME = libjplot.a
LIBDIR = /usr/blit/lib
BINDIR = /usr/blit/bin

MCC = mcc
MCFLAGSJ = -j
MCFLAGSM =

MSTRIP = mstrip

FRC =

OFILES = \
	arc.o\
	box.o\
	circle.o\
	close.o\
	dot.o\
	erase.o\
	label.o\
	line.o\
	linemod.o\
	move.o\
	open.o\
	point.o\
	space.o\
	subr.o

all: $(LIBNAME) jplot jplot.j jplot.m plot

$(LIBNAME): $(OFILES)
	ar r $(LIBNAME) $(OFILES)
	ranlib $(LIBNAME)

jplot: driver.o libjplot.a
	$(CC) driver.o libjplot.a $(LDFLAGS) -o jplot

jplot.j: jplot.c
	$(MCC) $(MCFLAGSJ) jplot.c -o jplot.j
	$(MSTRIP) jplot.j

jplot.m: jplot.c
	$(MCC) $(MCFLAGSM) jplot.c -o jplot.m
	$(MSTRIP) jplot.m

plot : plot.sh
	cp plot.sh plot

install: all
	$(INS) $(LIBNAME) $(LIBDIR)
	$(INS) jplot $(BINDIR)
	$(INS) jplot.m $(LIBDIR)
	$(INS) jplot.j $(LIBDIR)
	$(INS) plot $(BINDIR)

clean:
	-rm -f *.o

clobber:	clean
	-rm -f $(LIBNAME) jplot jplot.j jplot.m plot

arc.o: \
	jplot.h \
	$(FRC)

box.o: \
	jplot.h \
	$(FRC)

circle.o: \
	jplot.h \
	$(FRC) 

close.o: jplot.h \
	/usr/include/sgtty.h \
	$(FRC)

dot.o: \
	jplot.h \
	$(FRC)

driver.o: \
	/usr/include/stdio.h \
	$(FRC)

erase.o: \
	jplot.h \
	$(FRC)

jplot.o: \
	jerq.h \
	font.h \
	jplot.h \
	$(FRC)

label.o: \
	jplot.h \
	$(FRC)

line.o: \
	jplot.h \
	$(FRC)

linemod.o: \
	jplot.h \
	$(FRC)

move.o: \
	jplot.h \
	$(FRC)

open.o:	\
	jplot.h \
	/usr/include/sgtty.h \
	/usr/include/signal.h \
	/usr/include/stdio.h \
	/usr/blit/include/jioctl.h \
	$(FRC)

point.o: \
	jplot.h \
	$(FRC)

space.o: \
	jplot.h \
	$(FRC)


subr.o: \
	jplot.h \
	$(FRC)

FRC:

