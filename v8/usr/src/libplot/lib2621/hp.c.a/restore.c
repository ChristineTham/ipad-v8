#include "hp.h"
restore()
{ 
	if(--e1 <= e0){
		fprintf(stderr,"stack underflow\n");
		exit(1);
	}
	move(e1->copyx, e1->copyy); 
}
