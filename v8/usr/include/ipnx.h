/*
 * ipnx.h -- which system this is, for anything that needs to care.
 *
 * Generated from v8/RELEASE by tools/ipnx-release.py.  Do not edit; edit
 * RELEASE and regenerate, or --check will catch you.
 *
 * THE NAME OF THIS SYSTEM IS `ipnx Edition 8 Release 1.0'.  Two numbers, and
 * they belong to different people: the EDITION is Bell Labs' and is not ours
 * to increment, the RELEASE counts what this project has made of it.
 *
 * IPNX_RELSTR is the composed string -- release plus branch suffix, with the
 * suffix present only when the branch is not RELEASE.  Use it rather than
 * gluing IPNX_RELEASE and IPNX_BRANCH together at each call site: two
 * commands did that and both printed `1.0-RELEASE'.
 *
 * IPNX_VERSION is the one number to TEST.  It is
 *
 *      edition * 1000000 + major * 10000 + minor * 100 + patch
 *
 * which is monotonic across editions, so a port that wants a base new enough
 * to have some feature writes
 *
 *      #if IPNX_VERSION >= 8010000
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
#define IPNX_MAJOR      1
#define IPNX_MINOR      0
#define IPNX_PATCH      0
#define IPNX_VERSION    8010000

#define IPNX_BRANCH     "RELEASE"
#define IPNX_RELDATE    "2026-08-16"
#define IPNX_RELEASE    "1.0"
#define IPNX_RELSTR     "1.0"
#define IPNX_SYSNAME    "Edition 8"
#define IPNX_BANNER     "ipnx Edition 8 Release 1.0 (2026-08-16)"
