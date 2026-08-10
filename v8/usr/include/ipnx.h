/*
 * ipnx.h -- which system this is, for anything that needs to care.
 *
 * Generated from v8/RELEASE by tools/ipnx-release.py.  Do not edit; edit
 * RELEASE and regenerate, or --check will catch you.
 *
 * IPNX_VERSION is the one number to test.  It is
 *
 *      edition * 1000000 + major * 10000 + minor * 100 + patch
 *
 * which is monotonic across editions, so a port that wants a base new enough
 * to have some feature writes
 *
 *      #if IPNX_VERSION >= 8000300
 *
 * and does not have to know how Edition 8 relates to Edition 10.  This is
 * FreeBSD's __FreeBSD_version idea, and it is here rather than in
 * <sys/param.h> because the tape hardlinks usr/include/sys/param.h and
 * usr/sys/h/param.h into one file, git cannot store a hardlink, and anything
 * added to one copy would quietly rot in the other.
 *
 * Ports depend on the base.  The base never depends on a port.
 */

#define IPNX_EDITION    8
#define IPNX_MAJOR      0
#define IPNX_MINOR      3
#define IPNX_PATCH      0
#define IPNX_VERSION    8000300

#define IPNX_BRANCH     "CURRENT"
#define IPNX_RELDATE    "2026-08-10"
#define IPNX_RELEASE    "0.3.0"
#define IPNX_SYSNAME    "Eighth Edition"
#define IPNX_BANNER     "Eighth Edition Release 0.3.0-CURRENT (2026-08-10)"
