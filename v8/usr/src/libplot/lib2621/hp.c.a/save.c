#include "hp.h"
save()
{ 
	if(++e1 > &E[8]){
		fprintf(stderr,"stack overflow\n");
		exit(1);
	}
	pcopy(e1-1,e1);
}
