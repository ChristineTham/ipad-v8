#include "hp.h"
circle(xxc, yyc, rr) 
double	xxc, yyc, rr;
{
	if (rr > 0) 
		rr = -rr;
	arc(xxc , yyc + rr, xxc , yyc + rr, xxc, yyc, rr);
}
