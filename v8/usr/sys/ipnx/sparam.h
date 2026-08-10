/*
 *  Parameters for stream IO
 *
 *  Every machine directory carries one of these beside its `conf' -- alice,
 *  research and forbes all do -- and nine kernel sources include it
 *  (sys/streamio.c, dev/stream.c, dev/conf.c, dev/streamconf.c, dev/dk.c,
 *  dev/ec.c, dev/mem.c, dev/cmcld.c, inet/ip_subr.c).  Without it the build
 *  stops at "Make: Don't know how to make sparam.h" before compiling a line.
 *
 *  These are alice's numbers verbatim, and deliberately not research's.
 *  research is a smaller machine (NQUEUE 512, NSTREAM 128) and defines no
 *  NDKLINE at all, because it has no Datakit; ours takes alice's hardware,
 *  and our conf keeps `pseudo-device dkp 256' and `kdi 96', so NDKLINE has
 *  to be here.  alice's values are also the ones the shipped kernel runs
 *  with, which makes them the tested ones on this hardware.
 *
 *  Not to be confused with the queue sizing our netfs work changed: that is
 *  strdata's high and low water marks in sys/streamio.c (512/256 -> 8192/4096
 *  for phase N6), which is bytes per queue rather than how many queues there
 *  are.
 */

#define	NQUEUE	2048
#define	NSTREAM	512
#define	NBLK64	1024
#define	NBLK16	1024
#define	NBLKBIG	64
#define	NBLK4	512

/*
 *  Datakit channels
 */
#define	NDKLINE	256
