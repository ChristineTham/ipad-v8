/* resize-scope: boot a stock 5620, then resize it while it runs.
 *
 * The question this settles is not "does a bigger framebuffer fit" -- it does,
 * above the 1 MB ceiling the firmware's own maxaddr table imposes -- but which
 * parts of the terminal actually follow the new geometry.
 *
 * The 5620 keeps its screen description in exactly one place: a 20-byte Bitmap
 * called `display`, at 0x9ca8 in firmware 8;7;3, declared in AT&T's bootrom.s
 * under the comment "The display bitmap in rom at last!". It is .data linked
 * into ROM and never copied to RAM, so it is both the template and the live
 * structure. Every blit the firmware performs goes through it.
 *
 * What does NOT come from it is the text grid. setup.h computes
 *
 *      XCMAX ((XMAX-2*XMARGIN)/CW-1)      CW = 9, XMARGIN = 3, XMAX = 800
 *      YCMAX ((YMAX-2*YMARGIN)/NS-3)      NS = 14, YMARGIN = 3, YMAX = 1024
 *
 * at compile time -- 87 and 69, i.e. 88 columns by 70 rows -- and vitty.c
 * compares against those constants everywhere it wraps, scrolls or clears.
 * They are folded into the instruction stream: the short 800 appears just
 * three times in the whole 64 KB image, and only one of those is `display`.
 *
 * So this test measures the two independently:
 *
 *   text  -- feed 240 characters and find the rightmost lit pixel. The ROM's
 *            dumb terminal should wrap at XCMAX no matter what the screen is,
 *            putting that pixel at XMARGIN + 87*CW + 8 = 794 at the very most.
 *
 *   ink   -- park the mouse beyond the old right edge. The cursor is drawn
 *            through `display` and clipped to display.rect, so ink out there
 *            means the firmware really has taken the new geometry.
 *
 *   cc -O2 -o resize-scope test/resize-scope.c <libdmd_core.a> -Iinclude
 *   ./resize-scope [width] [height] [multiplier] [boot-seconds]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "dmdcore.h"

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static double hz_g;
static double t0_g;
static unsigned long long steps_g;

/* Run the terminal for `secs`, pacing it the way the app does. dmd_core's
   DUART hands over one character per real-time interval derived from the
   programmed baud rate, so the emulated CPU must not run flat out. */
static void run_for(double secs)
{
    double until = now_s() + secs;
    long long iter = 0;
    while (now_s() < until) {
        dmd_step_loop(500);
        steps_g += 500;
        if (++iter % 100 == 0) {
            double virt = (double)steps_g / hz_g, real = now_s() - t0_g;
            if (virt > real + 0.002)
                usleep((useconds_t)((virt - real) * 1e6));
        }
    }
}

struct ink {
    int right;      /* rightmost lit pixel, -1 if none */
    int bottom;     /* lowest lit row */
    int rows;       /* rows carrying any ink */
    long lit;       /* lit pixels */
};

static struct ink survey(uint32_t w, uint32_t h)
{
    const uint8_t *fb = dmd_video_ram();
    struct ink k = { -1, -1, 0, 0 };
    for (uint32_t y = 0; y < h; y++) {
        int any = 0;
        for (uint32_t x = 0; x < w; x++)
            if (fb[(y * (w / 8)) + (x / 8)] & (0x80 >> (x % 8))) {
                any = 1;
                k.lit++;
                if ((int)x > k.right) k.right = (int)x;
            }
        if (any) { k.rows++; k.bottom = (int)y; }
    }
    return k;
}

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

static void feed(const char *what, int n)
{
    for (int i = 0; i < n; i++)
        dmd_rs232_rx((uint8_t)what[i % (int)strlen(what)]);
}

int main(int argc, char **argv)
{
    uint32_t nw = argc > 1 ? (uint32_t)atoi(argv[1]) : 1408;
    uint32_t nh = argc > 2 ? (uint32_t)atoi(argv[2]) : 800;
    double mult = argc > 3 ? atof(argv[3]) : 2.0;
    double boot = argc > 4 ? atof(argv[4]) : 25.0;
    uint32_t w = 0, h = 0;

    hz_g = 10e6 * mult;

    /* No dmd_set_screen: boot exactly the machine AT&T shipped. */
    if (dmd_init(1) != DMD_SUCCESS) {
        fprintf(stderr, "dmd_init failed\n");
        return 1;
    }
    dmd_get_screen(&w, &h);
    printf("# booting stock %ux%u at %.0f MHz emulated\n", w, h, hz_g / 1e6);

    t0_g = now_s();
    run_for(boot);
    struct ink after_boot = survey(w, h);
    printf("# self-test settled: %ld lit pixels, %d rows, rightmost x=%d\n",
           after_boot.lit, after_boot.rows, after_boot.right);

    /* --- text before the resize ------------------------------------- */
    feed("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 240);
    run_for(3.0);
    struct ink t1 = survey(w, h);
    printf("# 240 chars at %ux%u: rightmost x=%d, %d rows of ink\n",
           w, h, t1.right, t1.rows);
    dump_pgm("resize-before.pgm", w, h);

    /* --- resize the running machine --------------------------------- */
    printf("\n# dmd_resize_screen(%u, %u) ...\n", nw, nh);
    if (dmd_resize_screen(nw, nh) != DMD_SUCCESS) {
        fprintf(stderr, "dmd_resize_screen refused %ux%u\n", nw, nh);
        return 1;
    }
    dmd_get_screen(&w, &h);
    printf("# now %ux%u; framebuffer is %u bytes\n", w, h, (w / 8) * h);

    /* Is the machine still alive? A halted WE32100 stops changing its PC. */
    uint32_t pc1 = 0, pc2 = 0;
    dmd_get_pc(&pc1);
    run_for(1.0);
    dmd_get_pc(&pc2);
    printf("# CPU after resize: pc %#010x -> %#010x (%s)\n",
           pc1, pc2, pc1 == pc2 ? "STOPPED" : "running");

    /* --- text after the resize -------------------------------------- */
    feed("\033[H\033[J", 6);                 /* home, clear */
    run_for(1.0);
    feed("ABCDEFGHIJKLMNOPQRSTUVWXYZ", 240);
    run_for(3.0);
    struct ink t2 = survey(w, h);
    printf("# 240 chars at %ux%u: rightmost x=%d, %d rows of ink\n",
           w, h, t2.right, t2.rows);

    /* --- does the firmware draw beyond the old right edge? ----------- */
    for (uint32_t x = 100; x < nw - 40; x += 20) {
        dmd_mouse_move((uint16_t)x, (uint16_t)(nh / 2));
        run_for(0.05);
    }
    run_for(1.0);
    struct ink t3 = survey(w, h);
    printf("# after sweeping the mouse to x=%u: rightmost x=%d\n",
           nw - 40, t3.right);
    dump_pgm("resize-after.pgm", w, h);

    /* --- scrolling, which is where a SHORTER screen bites -------------
       YCMAX is compiled in at 69, so the ROM scrolls when the cursor passes
       text row 69 -- pixel row 69*14+3 = 969. On a screen shorter than that
       the firmware addresses rows the CRT no longer has. Feed enough lines to
       drive it past the bottom and see where the ink actually ends. */
    feed("\033[H\033[J", 6);
    run_for(1.0);
    /* Paced: the DUART is a real-time character pacer and the rx FIFO drops
       anything fed faster than it drains, so a burst measures the FIFO, not
       the geometry. */
    for (int i = 0; i < 90; i++) {
        feed("scroll test line\r\n", 18);
        run_for(0.06);
    }
    run_for(2.0);
    struct ink t4 = survey(w, h);
    printf("# after 90 lines: lowest ink row y=%d of %u, %d rows of ink\n",
           t4.bottom, h, t4.rows);
    printf("#   ROM scrolls at text row 69 = pixel row %d; screen is %u tall"
           "  (%s)\n", 69 * 14 + 3, h,
           69 * 14 + 3 < (int)h ? "fits" : "OVERFLOWS - rows drawn off-screen");

    printf("\n# VERDICT\n");
    printf("#   text grid   : wrapped at x=%d before, x=%d after"
           "  (%s)\n", t1.right, t2.right,
           t2.right > t1.right + 8 ? "WIDER" : "unchanged - XCMAX is compiled in");
    printf("#   drawable    : ink reaches x=%d of %u"
           "  (%s)\n", t3.right, nw - 1,
           t3.right > 800 ? "PAST the stock edge" : "still inside 800");
    return 0;
}
