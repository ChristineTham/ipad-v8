libtr.a: tr.c.a
	mkdir xplot
	cp tr.c.a/* xplot
	cd xplot;cc -c -O *.c
	cd xplot;ar rc ../libtr.a *.o
	rm -r xplot

install:	libtr.a
	mv libtr.a /usr/lib
	ranlib /usr/lib/libtr.a

clean:
	rm -f libtr.a trplot driver.o
