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

set(ALL_SOURCES ${VAX_SOURCES} ${PDP11_SOURCES} ${SIM_SOURCES})
list(TRANSFORM ALL_SOURCES PREPEND "${SIMH_DIR}/")

add_library(simhvax STATIC ${ALL_SOURCES} src/simh_shim.c)

target_include_directories(simhvax
  PRIVATE "${SIMH_DIR}" "${SIMH_DIR}/VAX" "${SIMH_DIR}/PDP11"
  PUBLIC  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_compile_definitions(simhvax PRIVATE
  VM_VAX VAX_780 USE_INT64 USE_ADDR64
  _GNU_SOURCE HAVE_SYS_IOCTL HAVE_UTIME HAVE_GLOB NDEBUG=1)

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
