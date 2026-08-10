lib4014.a: tek.c.a
	mkdir xplot
	cp tek.c.a/* xplot
	cd xplot;cc -c -O *.c
	cd xplot;ar rc ../lib4014.a *.o
	rm -r xplot

install:	lib4014.a
	mv lib4014.a /usr/lib
	ranlib /usr/lib/lib4014.a
clean:
	rm -fr xplot lib4014.a *.o
