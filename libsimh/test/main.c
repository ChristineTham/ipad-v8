/* Desktop harness for the static library: proves the -Dmain rename and
 * the trimmed source list boot V8 before any iOS code exists.
 * Usage: vax780cli <config-file>   (same configs as the stock binary) */
#include <stdio.h>
#include "simh_vax780.h"

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <config-file>\n", argv[0]);
        return 2;
    }
    return simh_vax780_run(argv[1]);
}
