/* DmdCore smoke test: prove the FFI + patched core boot the 8;7;3
 * firmware into terminal mode under the app's pacing model (10 MHz
 * wall-clock, dmd_step_loop(500) batches).
 *
 * A booted 5620 shows an almost-black screen with just a cursor (~26 lit
 * bytes) — text appears only when the HOST sends bytes. So the proof is
 * an echo test: settle the firmware, then feed "HELLO 5620..." down the
 * RS232 and require the lit-pixel count to jump (glyphs rendered). */
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "dmdcore.h"

static int lit_bytes(void)
{
    const uint8_t *fb = dmd_video_ram();
    int lit = 0;
    for (int i = 0; i < 102400; i++)
        if (fb[i]) lit++;
    return lit;
}

int main(void)
{
    if (dmd_init(1) != DMD_SUCCESS) {
        fprintf(stderr, "FAIL: dmd_init(1) (8;7;3 firmware) failed\n");
        return 1;
    }

    struct timespec t0, now;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    unsigned long long steps = 0;
    const char *msg = "HELLO 5620 FROM THE FFI\r\n";
    size_t msg_i = 0;
    unsigned long long next_char_at = 30000000ULL;   /* settle 3s virtual first */
    uint8_t b;
    int baseline = -1;

    for (int iter = 1; iter <= 100000; iter++) {     /* up to 50M steps */
        dmd_step_loop(500);
        steps += 500;
        if (iter % 100 == 0) {
            clock_gettime(CLOCK_MONOTONIC, &now);
            double real = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec) / 1e9;
            double virt = steps / 10e6;
            if (virt > real + 0.002)
                usleep((useconds_t)((virt - real) * 1e6));
        }
        while (dmd_rs232_tx(&b) == DMD_SUCCESS) { }
        while (dmd_keyboard_tx(&b) == DMD_SUCCESS) { }

        if (steps >= next_char_at && msg_i < strlen(msg)) {
            if (baseline < 0) {
                baseline = lit_bytes();
                uint32_t pc = 0;
                dmd_get_pc(&pc);
                printf("settled: pc=%08x baseline_lit=%d\n", pc, baseline);
            }
            dmd_rs232_rx((uint8_t)msg[msg_i++]);
            next_char_at = steps + 20000;            /* ~2ms/char at 10MHz */
        }
        if (msg_i == strlen(msg) && steps > next_char_at + 5000000ULL)
            break;                                   /* 0.5s to finish drawing */
    }

    int lit = lit_bytes();
    printf("after echo: lit=%d (baseline %d)\n", lit, baseline);
    if (baseline >= 0 && lit > baseline + 100) {
        printf("SMOKE OK: terminal mode echoed text to the framebuffer\n");
        return 0;
    }
    fprintf(stderr, "SMOKE FAIL: no glyphs rendered (lit %d vs baseline %d)\n",
            lit, baseline);
    return 1;
}
