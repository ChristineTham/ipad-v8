/* Force-included on iOS builds only (see CMakeLists.txt).
 *
 * The iOS SDK marks a few POSIX calls __IOS_PROHIBITED, which makes any
 * reference a hard compile error. open-simh's scp uses system() for the
 * `! command` shell escape -- meaningless inside an iOS app. Mapping the
 * call to an inert stub here keeps the upstream tree pristine (project
 * convention: no source patches without a logged rationale).
 *
 * The libc headers must be included BEFORE the macros are defined, so the
 * real prototypes are already declared and the macros only rewrite call
 * sites in simh code, never the declarations themselves.
 */
#ifndef SIMH_IOS_COMPAT_H
#define SIMH_IOS_COMPAT_H

#include <stdlib.h>
#include <stdio.h>

static inline int simh_ios_no_system(const char *cmd) { (void)cmd; return -1; }
#define system(cmd) simh_ios_no_system(cmd)

#endif /* SIMH_IOS_COMPAT_H */
