/* idle-scope: watch a 5620 come up from reset and then sit there.
 *
 * Two questions, one instrument:
 *
 *  1. Where does power-on time actually go? The ROM's self-test draws each
 *     stage's name (ROM TEST, SHORTRAM TEST, RAM TEST, NONVOLATILE MEMORY
 *     TEST, I/O TEST, EXTERNAL DUART TEST, ...) as it runs, so a change in the
 *     lit-pixel count is a stage boundary. Timing those against BOTH the wall
 *     clock and the emulated instruction count separates the stages that are
 *     CPU-bound (they scale with the emulated clock) from the ones that are
 *     wall-clock bound (they do not) -- dmd_core's DUART hands over one
 *     character per real-time interval derived from the programmed baud rate,
 *     so anything that loops the serial port back to itself costs real seconds
 *     no matter how fast the CPU runs.
 *
 *  2. Is the idle terminal in a tight loop? SIMH saves ~70% of a core at an
 *     idle V8 prompt by recognising the guest's idle loop; dmd_core has no
 *     such thing and burns whatever the emulated clock costs. If the settled
 *     firmware sits in a small PC window, the same trick is available to us
 *     from outside the core, through dmd_get_pc().
 *
 *   cc -O2 -o idle-scope test/idle-scope.c <libdmd_core.a> -Iinclude
 *   ./idle-scope [multiplier] [seconds] [width] [height] [nvram-file]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "dmdcore.h"

#define SAMPLE    50000            /* steps between samples */
#define MAXPC     4096

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int fb_bytes_g = 102400;

static int lit_bytes(void)
{
    const uint8_t *fb = dmd_video_ram();
    int lit = 0;
    for (int i = 0; i < fb_bytes_g; i++)
        if (fb[i]) lit++;
    return lit;
}

/* Dump the 1-bit framebuffer as a PGM. Skew or wrap in this image is the
   whole test: it says whether the ROM is drawing at the stride we told it. */
static void dump_pgm(const char *path, uint32_t w, uint32_t h)
{
    const uint8_t *fb = dmd_video_ram();
    FILE *f = fopen(path, "wb");
    if (!f)
        return;
    fprintf(f, "P5\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x++) {
            uint8_t byte = fb[(y * (w / 8)) + (x / 8)];
            fputc((byte & (0x80 >> (x % 8))) ? 0 : 255, f);
        }
    fclose(f);
    fprintf(stderr, "wrote %s (%ux%u)\n", path, w, h);
}

int main(int argc, char **argv)
{
    double mult = argc > 1 ? atof(argv[1]) : 2.0;   /* app default: "Fast" */
    double secs = argc > 2 ? atof(argv[2]) : 25.0;
    double hz = 10e6 * mult;
    uint32_t sw = 800, sh = 1024;

    if (argc > 4) {                                 /* [width] [height] */
        sw = (uint32_t)atoi(argv[3]);
        sh = (uint32_t)atoi(argv[4]);
        if (dmd_set_screen(sw, sh) != DMD_SUCCESS) {
            fprintf(stderr, "dmd_set_screen(%u,%u) refused\n", sw, sh);
            return 1;
        }
    }
    dmd_get_screen(&sw, &sh);
    const int fb_bytes = (int)(sw / 8) * (int)sh;

    if (dmd_init(1) != DMD_SUCCESS) {               /* firmware 8;7;3 */
        fprintf(stderr, "dmd_init failed\n");
        return 1;
    }

    /* The app restores saved NVRAM before it steps the terminal (A3), and
       NVRAM carries the programmed baud rate -- which is what sets the DUART's
       real-time per-character delay. Feeding a real saved NVRAM in is the only
       way to reproduce a user's actual power-on. */
    if (argc > 5) {                                 /* [nvram-file] */
        static uint8_t nv[8192];
        FILE *f = fopen(argv[5], "rb");
        if (!f || fread(nv, 1, sizeof nv, f) != sizeof nv) {
            fprintf(stderr, "could not read 8192-byte NVRAM from %s\n", argv[5]);
            return 1;
        }
        fclose(f);
        dmd_set_nvram(nv);
        printf("# NVRAM restored from %s\n", argv[5]);
    }

    double t0 = now_s();
    unsigned long long steps = 0;
    long long iter = 0;
    int last_lit = -1;
    double last_change_t = 0, last_change_v = 0;

    /* PC census over the last stretch, to see whether an idle terminal is
       looping somewhere small. Cheap open-addressed count table. */
    uint32_t pc_key[MAXPC];
    uint32_t pc_cnt[MAXPC];
    memset(pc_key, 0xff, sizeof pc_key);
    memset(pc_cnt, 0, sizeof pc_cnt);
    unsigned long long pc_samples = 0;
    double census_from = secs * 0.6;               /* only once settled */

    fb_bytes_g = fb_bytes;
    printf("# 5620 %ux%u at %.0f MHz emulated (app multiplier %.1fx)\n", sw, sh, hz / 1e6, mult);
    printf("# %8s %10s %8s   %s\n", "wall(s)", "Msteps", "lit", "event");

    while (now_s() - t0 < secs) {
        dmd_step_loop(500);
        steps += 500;
        iter++;

        /* Same wall-clock pacing the app uses (Terminal5620.swift). */
        if (iter % 100 == 0) {
            double virt = (double)steps / hz;
            double real = now_s() - t0;
            if (virt > real + 0.002)
                usleep((useconds_t)((virt - real) * 1e6));
        }

        if (steps % SAMPLE == 0) {
            double wall = now_s() - t0;
            int lit = lit_bytes();
            if (lit != last_lit) {
                if (last_lit >= 0)
                    printf("  %8.2f %10.1f %8d   screen changed  (+%.2f s wall, "
                           "+%.1f Msteps since previous)\n",
                           wall, steps / 1e6, lit,
                           wall - last_change_t, (steps - last_change_v) / 1e6);
                last_lit = lit;
                last_change_t = wall;
                last_change_v = steps;
            }
            if (wall > census_from) {
                uint32_t pc = 0;
                if (dmd_get_pc(&pc) == DMD_SUCCESS) {
                    uint32_t h = (pc * 2654435761u) % MAXPC;
                    while (pc_key[h] != 0xffffffffu && pc_key[h] != pc)
                        h = (h + 1) % MAXPC;
                    pc_key[h] = pc;
                    pc_cnt[h]++;
                    pc_samples++;
                }
            }
        }
    }

    double wall = now_s() - t0;
    printf("\n# ran %.1f Msteps in %.1f s wall = %.1f MHz effective "
           "(%.0f%% of the %.0f MHz asked for)\n",
           steps / 1e6, wall, steps / wall / 1e6,
           100.0 * (steps / wall) / hz, hz / 1e6);

    /* Top PCs while settled. A handful of addresses covering most samples
       means a tight loop -- i.e. an idle loop we could detect and sleep on. */
    printf("\n# PC census while settled (%llu samples, one per %d steps)\n",
           pc_samples, SAMPLE);
    for (int shown = 0; shown < 12; shown++) {
        int best = -1;
        for (int i = 0; i < MAXPC; i++)
            if (pc_cnt[i] && (best < 0 || pc_cnt[i] > pc_cnt[best]))
                best = i;
        if (best < 0 || pc_samples == 0)
            break;
        printf("   0x%08x  %6u  %5.1f%%\n", pc_key[best], pc_cnt[best],
               100.0 * pc_cnt[best] / pc_samples);
        pc_cnt[best] = 0;
    }
    /* Feed a line longer than the old 100-column screen and let the ROM's own
       terminal emulator lay it out. Where it wraps says whether the firmware
       has really taken the new geometry, or is just not crashing. */
    for (int i = 0; i < 240; i++)
        dmd_rs232_rx((uint8_t)('A' + (i % 26)));
    double until = now_s() + 3.0;
    while (now_s() < until) {
        dmd_step_loop(500);
        steps += 500;
        if (++iter % 100 == 0) {
            double virt = (double)steps / hz, real = now_s() - t0;
            if (virt > real + 0.002)
                usleep((useconds_t)((virt - real) * 1e6));
        }
    }
    {
        const uint8_t *fb = dmd_video_ram();
        int rightmost = -1, rows = 0;
        for (uint32_t y = 0; y < sh; y++) {
            int any = 0;
            for (uint32_t x = 0; x < sw; x++)
                if (fb[(y * (sw / 8)) + (x / 8)] & (0x80 >> (x % 8))) {
                    any = 1;
                    if ((int)x > rightmost) rightmost = (int)x;
                }
            rows += any;
        }
        printf("\n# after 240 chars: rightmost lit pixel = %d (screen is %u wide),"
               " %d rows have ink\n", rightmost, sw, rows);
    }
    dump_pgm("idle-scope.pgm", sw, sh);
    return 0;
}
