libpen.a: pen.c.a
	mkdir xplot
	cp pen.c.a/* xplot
	cd xplot;cc -c -O *.c
	cd xplot;ar rc ../libpen.a *.o
	rm -r xplot

install:	libpen.a
	cp libpen.a /usr/lib
	ranlib /usr/lib/libpen.a

clean:
	rm -rf xplot libpen.a penplot driver.o
