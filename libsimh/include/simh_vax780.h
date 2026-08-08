#ifndef SIMH_VAX780_H
#define SIMH_VAX780_H

#ifdef __cplusplus
extern "C" {
#endif

/* Run the SIMH vax780 main loop with the given startup/config file.
 * Blocks until the simulator exits -- call it on a dedicated thread.
 *
 * All runtime control happens through the telnet console the config file
 * sets up (`set console telnet=...`): the simulated console stream, the
 * WRU stop character (^E), and the sim> command prompt (save / cont /
 * restore) all travel over that one localhost socket.
 *
 * Returns scp's exit status. Note: an `exit` command typed at sim> calls
 * exit(3) and terminates the whole process -- the app must not expose it.
 */
int simh_vax780_run(const char *config_path);

/* Ask the running simulator to stop, as if SIGINT arrived: scp unwinds to
 * the sim> prompt on the telnet console, where save/cont/restore commands
 * can be issued. Safe to call from any thread. Necessary because the WRU
 * character (^E) only stops the simulator when the console is a local tty,
 * never over a telnet console (sim_console.c's telnet path does not check
 * the interrupt character). */
void simh_vax780_request_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* SIMH_VAX780_H */
