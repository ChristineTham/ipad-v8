/* keyboard-scope: does a *widened* 5620 still talk?
 *
 * Every test so far has driven the terminal in one direction -- bytes in on
 * RS232, ink out on the screen -- because that is what `mux` and the resize
 * work needed. The keyboard direction has never been measured at all, and it
 * is the one the app's user actually notices: type, and nothing happens.
 *
 * That matters now because widening the screen is not one change but two, and
 * only the first is data:
 *
 *   dmd_resize_screen()  rewrites the 20-byte `display` Bitmap in ROM .data
 *                        and reallocates the framebuffer. Nothing executable
 *                        is touched.
 *
 *   dmd_set_columns()    rewrites up to 24 *instruction operands* -- every
 *                        byte immediate in the image whose value is 87 or 88 --
 *                        and then repairs the ROM checksum. The scan cannot
 *                        tell a text-grid constant from any other byte that
 *                        happens to equal 87, so a false positive lands in the
 *                        middle of unrelated code.
 *
 * If one of those 24 rewrites falls in the keyboard or DUART path, the
 * terminal would draw perfectly and be deaf. This measures both directions
 * either side of the patch:
 *
 *   keyboard -> host   dmd_keyboard_rx('X') should surface as 'X' on
 *                      dmd_rs232_tx. That is the whole path the app's
 *                      keystrokes take.
 *   host -> screen     dmd_rs232_rx() should light pixels.
 *
 *   cc -O2 -o keyboard-scope test/keyboard-scope.c <libdmd_core.a> -Iinclude
 *   ./keyboard-scope [width] [height] [columns]
 *
 * With no arguments it runs the app's exact Wide preset: 1152x1024, 127
 * columns. Pass "800 1024 0" for the Original preset as a control.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "dmdcore.h"

static double hz_g;

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* Pace the CPU the way the app does: the DUART is a wall-clock character
   pacer, and a flat-out CPU starves its serial handshakes (A0). */
static void run_for(double secs)
{
    double t0 = now_s(), until = t0 + secs;
    unsigned long long steps = 0;
    while (now_s() < until) {
        dmd_step_loop(500);
        steps += 500;
        double virt = (double)steps / hz_g;
        double real = now_s() - t0;
        if (virt > real + 0.002)
            usleep((useconds_t)((virt - real) * 1e6));
    }
}

/* The app's own self-test-done test: the firmware's idle loop is
   0x5354-0x5389, and a still screen is NOT a sound signal (selftest.c blocks
   in t_kbd() with the screen mid-test). */
static int wait_for_idle(double limit)
{
    double t0 = now_s();
    int consecutive = 0;
    while (now_s() - t0 < limit) {
        run_for(0.05);
        uint32_t pc = 0;
        if (dmd_get_pc(&pc) == DMD_SUCCESS && pc >= 0x5354 && pc <= 0x5389) {
            if (++consecutive >= 3) {
                printf("# self-test done at %.2f s (pc %#06x)\n", now_s() - t0, pc);
                return 1;
            }
        } else {
            consecutive = 0;
        }
    }
    return 0;
}

static long lit_pixels(uint32_t w, uint32_t h)
{
    const uint8_t *fb = dmd_video_ram();
    if (!fb)
        return -1;
    long n = 0;
    for (size_t i = 0; i < (size_t)(w / 8) * h; i++)
        for (int b = 0; b < 8; b++)
            n += (fb[i] >> b) & 1;
    return n;
}

/* Type `text` at the keyboard and collect whatever the terminal puts on the
   RS232 line. The firmware's key FIFO is ~3 deep and wall-clock paced, so
   keys have to be spaced or they are simply dropped (A0). */
static int type_and_collect(const char *text, char *out, size_t cap)
{
    size_t got = 0;
    for (const char *p = text; *p; p++) {
        dmd_keyboard_rx((uint8_t)*p);
        run_for(0.12);
        uint8_t b;
        while (dmd_rs232_tx(&b) == DMD_SUCCESS && got + 1 < cap)
            out[got++] = (char)(b & 0x7f);
    }
    run_for(0.3);
    uint8_t b;
    while (dmd_rs232_tx(&b) == DMD_SUCCESS && got + 1 < cap)
        out[got++] = (char)(b & 0x7f);
    out[got] = 0;
    return (int)got;
}

struct result { int typed; long ink; char echoed[128]; };

static struct result measure(const char *label, uint32_t w, uint32_t h)
{
    struct result r;
    memset(&r, 0, sizeof r);

    /* keyboard -> host */
    r.typed = type_and_collect("hello", r.echoed, sizeof r.echoed);

    /* host -> screen: the ROM terminal draws what arrives on RS232. */
    long before = lit_pixels(w, h);
    for (const char *p = "WXYZWXYZWXYZ"; *p; p++)
        dmd_rs232_rx((uint8_t)*p);
    run_for(2.0);
    r.ink = lit_pixels(w, h) - before;

    printf("# %-22s keyboard->host %d bytes %-12s screen +%ld pixels\n",
           label, r.typed, r.typed ? r.echoed : "(NOTHING)", r.ink);
    return r;
}

int main(int argc, char **argv)
{
    uint32_t want_w = argc > 1 ? (uint32_t)atoi(argv[1]) : 1152;
    uint32_t want_h = argc > 2 ? (uint32_t)atoi(argv[2]) : 1024;
    int want_cols = argc > 3 ? atoi(argv[3]) : 127;

    hz_g = 10e6 * 2.0;                       /* the app's default 2x */

    /* Exactly the app's power-on: authentic 800x1024 until the self-test is
       over, because selftest.c clears screen memory at a hardcoded 0x700000. */
    dmd_set_screen(800, 1024);
    if (dmd_init(1) != DMD_SUCCESS) {
        fprintf(stderr, "dmd_init failed\n");
        return 1;
    }
    if (!wait_for_idle(30.0)) {
        fprintf(stderr, "terminal never reached its idle loop\n");
        return 1;
    }

    struct result stock = measure("stock 800x1024:", 800, 1024);

    if (want_w == 800 && want_h == 1024 && want_cols == 0) {
        printf("\n# control run only, no resize requested\n");
        return stock.typed > 0 ? 0 : 2;
    }

    printf("\n# dmd_resize_screen(%u, %u)\n", want_w, want_h);
    if (dmd_resize_screen(want_w, want_h) != DMD_SUCCESS) {
        fprintf(stderr, "resize refused\n");
        return 1;
    }
    run_for(0.5);
    struct result resized = measure("after resize:", want_w, want_h);

    int patched = 0;
    if (want_cols > 0) {
        patched = dmd_set_columns((uint32_t)want_cols);
        printf("\n# dmd_set_columns(%d) rewrote %d operands\n", want_cols, patched);
        if (patched < 0)
            return 1;
        run_for(0.5);
    }
    struct result final = measure("after grid patch:", want_w, want_h);

    printf("\n# VERDICT\n");
    printf("#   keyboard->host  stock %d, after resize %d, after grid patch %d\n",
           stock.typed, resized.typed, final.typed);
    printf("#   host->screen    stock %+ld, after resize %+ld, after grid patch %+ld\n",
           stock.ink, resized.ink, final.ink);
    if (stock.typed && resized.typed && !final.typed)
        printf("#   => the COLUMN PATCH makes the terminal deaf\n");
    else if (stock.typed && !resized.typed)
        printf("#   => the RESIZE makes the terminal deaf\n");
    else if (final.typed)
        printf("#   => the terminal still talks at %ux%u/%d columns\n",
               want_w, want_h, want_cols);
    return final.typed > 0 ? 0 : 2;
}
