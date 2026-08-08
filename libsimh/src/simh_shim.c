/* The library entry point. scp.c is compiled with -Dmain=simh_main
 * (see CMakeLists.txt), so the unmodified SIMH command processor becomes
 * callable. Everything else -- stop, save, continue -- goes through the
 * telnet console; this file should never grow much. */
#include "simh_vax780.h"

extern int simh_main(int argc, char *argv[]);

/* scp.c:  volatile t_bool stop_cpu;  (t_bool == int)
 * Setting it from another thread is exactly what scp's own SIGINT handler
 * does; the main loop polls it in sim_process_event and unwinds to sim>. */
extern volatile int stop_cpu;

int simh_vax780_run(const char *config_path)
{
    char *argv[] = { "vax780", (char *)config_path, 0 };
    return simh_main(2, argv);
}

void simh_vax780_request_stop(void)
{
    stop_cpu = 1;
}
