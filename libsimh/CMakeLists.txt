# open-simh vax780 as a static library (Track A1).
# Source list and defines mirror `make -n vax780` from open-simh (see
# work/opensimh-vax780-cmd.txt), minus everything an iOS app can't or
# shouldn't carry: no pcap/slirp networking, no SDL video, no editline,
# and -- deliberately -- no SIM_ASYNCH_IO: synchronous I/O is compiled in,
# making the V8-critical `set noasync` state permanent (simh issue #425).
cmake_minimum_required(VERSION 3.24)
project(simhvax C)

set(SIMH_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../work/opensimh" CACHE PATH
    "open-simh checkout (gitignored; cloned/pinned by build-xcframework.sh)")

set(VAX_SOURCES
  VAX/vax_cpu.c VAX/vax_cpu1.c VAX/vax_fpa.c VAX/vax_cis.c VAX/vax_octa.c
  VAX/vax_cmode.c VAX/vax_mmu.c VAX/vax_sys.c VAX/vax_syscm.c
  VAX/vax780_stddev.c VAX/vax780_sbi.c VAX/vax780_mem.c VAX/vax780_uba.c
  VAX/vax7x0_mba.c VAX/vax780_fload.c VAX/vax_uw.c VAX/vax780_syslist.c)

set(PDP11_SOURCES
  PDP11/pdp11_rl.c PDP11/pdp11_rq.c PDP11/pdp11_ts.c PDP11/pdp11_dz.c
  PDP11/pdp11_lp.c PDP11/pdp11_tq.c PDP11/pdp11_xu.c PDP11/pdp11_ry.c
  PDP11/pdp11_cr.c PDP11/pdp11_rp.c PDP11/pdp11_tu.c PDP11/pdp11_hk.c
  PDP11/pdp11_vh.c PDP11/pdp11_dmc.c PDP11/pdp11_dup.c PDP11/pdp11_td.c
  PDP11/pdp11_tc.c PDP11/pdp11_rk.c PDP11/pdp11_io_lib.c PDP11/pdp11_ch.c
  # Our Interlan NI1010 (libsimh/patches/); vax780_syslist.c references it
  # unconditionally once the patch is applied, so it must be compiled here too.
  PDP11/pdp11_il.c)

set(SIM_SOURCES
  scp.c sim_console.c sim_fio.c sim_timer.c sim_sock.c sim_tmxr.c
  sim_ether.c sim_tape.c sim_disk.c sim_serial.c sim_video.c sim_imd.c
  sim_card.c)

# SLiRP: user-mode TCP/IP, and the ONLY reason the guest has a network.
#
# This was left out at A1 as "everything an iOS app can't or shouldn't carry",
# alongside pcap and SDL. That was right about pcap -- which wants a raw-socket
# capability no sandboxed app has -- and wrong about SLiRP, which is the exact
# opposite: plain C over ordinary BSD sockets, no privilege, no kernel
# extension, nothing to ask the OS for. The whole N track then established that
# SLiRP is how the guest reaches the host at all, because it aliases 10.0.2.2
# to the host's own loopback (tcp_fconnect, "It's an alias") -- so netfs needs
# no port forwarding and works unchanged inside the sandbox.
#
# Without it the app gets `attach il nat:' -> "Command not allowed": the
# NI1010 is compiled in and autoconfig finds it, so the guest boots reporting
# a healthy il0 and cannot pass one packet. That is what shipped until now.
#
# HAVE_SLIRP_NETWORK is what sim_ether.c gates the `nat:' transport on;
# USE_SIMH_SLIRP_DEBUG (in upstream's own command line) is deliberately NOT
# set -- it only adds tracing.
file(GLOB SLIRP_SOURCES "${SIMH_DIR}/slirp/*.c" "${SIMH_DIR}/slirp_glue/*.c")

set(ALL_SOURCES ${VAX_SOURCES} ${PDP11_SOURCES} ${SIM_SOURCES})
list(TRANSFORM ALL_SOURCES PREPEND "${SIMH_DIR}/")
list(APPEND ALL_SOURCES ${SLIRP_SOURCES})

add_library(simhvax STATIC ${ALL_SOURCES} src/simh_shim.c)

target_include_directories(simhvax
  PRIVATE "${SIMH_DIR}" "${SIMH_DIR}/VAX" "${SIMH_DIR}/PDP11"
          "${SIMH_DIR}/slirp" "${SIMH_DIR}/slirp_glue"
          "${SIMH_DIR}/slirp_glue/qemu"
  PUBLIC  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_compile_definitions(simhvax PRIVATE
  VM_VAX VAX_780 USE_INT64 USE_ADDR64
  _GNU_SOURCE HAVE_SYS_IOCTL HAVE_UTIME HAVE_GLOB NDEBUG=1
  # BOTH of these are required and they do different jobs. USE_NETWORK is the
  # master switch: sim_ether.c wraps its real implementation in
  # `#if defined (USE_NETWORK) || defined (USE_SHARED)' and, failing that,
  # compiles a stub eth_open that returns SCPE_NOFNC. HAVE_SLIRP_NETWORK then
  # selects the `nat:' transport within it.
  #
  # With only HAVE_SLIRP_NETWORK the whole of slirp/ compiles and links into
  # the archive -- its own sources do not consult the switch -- and NOTHING
  # references it, so the linker drops every object and `attach il nat:'
  # still answers "Command not allowed". The archive looks correct under nm
  # (56 slirp symbols) while the app binary has none: check for an UNDEFINED
  # _sim_slirp_open, not a defined one.
  #
  # NOT USE_SHARED, which upstream's own command line uses: that means dlopen
  # a shared pcap, and it force-defines HAVE_PCAP_NETWORK. We want the
  # opposite -- SLiRP statically linked, no pcap, no raw sockets, nothing to
  # ask a sandbox for.
  #
  # USE_READER_THREAD is NOT optional once networking is on, and leaving it out
  # hangs the ATTACH -- long before any guest instruction runs.
  # eth_open -> eth_reflect -> eth_check_address_conflict_ex sends a loopback
  # probe and then drains the queue with
  #
  #     do { status = eth_read (dev, &recv, NULL); } while (recv.len > 0);
  #
  # which terminates only on a read that returns nothing. With a reader thread
  # eth_read pops a bounded queue and duly runs dry; polling SLiRP synchronously
  # it does not, and SIMH spins at 100% inside attach_cmd. boot.conf never
  # reaches `run 2', so the machine has no getty, no shell and no DZ answer --
  # it presents as an app that came up with a dead terminal, and nothing in the
  # log says "attach". Upstream's own vax780 command line carries this flag;
  # ours did not, which is why the desktop binary was fine and the app was not.
  USE_NETWORK HAVE_SLIRP_NETWORK USE_READER_THREAD)

target_compile_options(simhvax PRIVATE
  -std=c99 -U__STRICT_ANSI__ -O2 -fno-strict-overflow -finline-functions)

# The single deliberate modification to upstream: scp.c's main() becomes
# simh_main() so the app links it as a library entry point (src/simh_shim.c).
set_source_files_properties("${SIMH_DIR}/scp.c" PROPERTIES
  COMPILE_DEFINITIONS "main=simh_main")

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # Map POSIX calls the iOS SDK marks __IOS_PROHIBITED to inert stubs,
  # without touching upstream sources.
  target_compile_options(simhvax PRIVATE
    -include "${CMAKE_CURRENT_SOURCE_DIR}/include/ios_compat.h")
endif()

find_package(Threads REQUIRED)
target_link_libraries(simhvax INTERFACE Threads::Threads)

# Desktop smoke test: the same library, driven exactly like the app will
# drive it (config file in, telnet console out). Not part of the xcframework.
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  add_executable(vax780cli test/main.c)
  target_link_libraries(vax780cli PRIVATE simhvax)
endif()
