#ifndef DMDCORE_H
#define DMDCORE_H

/* dmd_core's built-in C FFI (DMD 5620: WE32100 CPU, DUART, 800x1024x1
 * framebuffer), from the patched canonical tree — git.loomcom.com rev
 * ee222b68 + tools/dmdbridge/patches/ (firmware 8;7;3 BREAK-as-0x00 +
 * 8x DUART serial turbo from A0; the two dmd_rs232*_break exports from
 * A2). The core is a global singleton behind a mutex: one 5620 per
 * process, callable from one thread at a time.
 *
 * Status codes: 0 = success, 1 = error, 2 = busy/empty.
 *
 * Pacing is the caller's job and it matters: the DUART is a wall-clock
 * state machine, so step the CPU at ~10 MHz of real time
 * (dmd_step_loop(500) batches with catch-up sleeps), space
 * host->terminal bytes ~1 per 1000 steps, and keyboard bytes ~100 ms
 * apart (the firmware FIFO is 3 deep). */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DMD_SUCCESS 0
#define DMD_ERROR   1
#define DMD_BUSY    2

/* version 1 = firmware 8;7;3 (required by Research Unix mux). */
int32_t dmd_init(uint8_t version);

/* Emulated CRT geometry (ipnx patch). Width must be a multiple of 32 (a
 * Bitmap's stride is counted in 32-bit Words) and at most 2048x2048.
 *
 * dmd_set_screen applies before dmd_init. dmd_resize_screen retargets a
 * terminal that is already running: nothing is allocated and the CPU is not
 * reset, so the DUART, NVRAM and host connection all survive. Prefer it --
 * booting at the stock 800x1024 and resizing afterwards means the power-on
 * self-test runs against the pristine ROM.
 *
 * After a resize the caller must re-read dmd_video_ram(): both the pointer and
 * the length change, and the new screen comes back cleared. */
int32_t dmd_set_screen(uint32_t width, uint32_t height);
int32_t dmd_resize_screen(uint32_t width, uint32_t height);
int32_t dmd_get_screen(uint32_t *width, uint32_t *height);

int32_t dmd_step(void);
int32_t dmd_step_loop(size_t steps);

/* 102,400 bytes: row-major, 100 bytes/row, MSB-first, 1 = lit phosphor. */
const uint8_t *dmd_video_ram(void);
int32_t dmd_video_ram_dirty(void);

int32_t dmd_rs232_rx(uint8_t c);                 /* host -> terminal */
int32_t dmd_rs232_tx(uint8_t *tx_char);          /* DMD_BUSY = queue empty */
int32_t dmd_rs232_break(void);                   /* host -> terminal BREAK */
int32_t dmd_rs232_tx_break(uint8_t *flag);       /* *flag=1: terminal sent BREAK */

int32_t dmd_keyboard_rx(uint8_t c);
int32_t dmd_keyboard_tx(uint8_t *tx_char);       /* drain (bell clicks) */

/* Free-running counters (muxterm integrates deltas, y counts UP the
 * screen) — feed wrapping counter values, never absolute positions.
 * Buttons 0..2; mux's layer menu lives on button index 2. */
int32_t dmd_mouse_move(uint16_t x, uint16_t y);
int32_t dmd_mouse_down(uint8_t button);
int32_t dmd_mouse_up(uint8_t button);

int32_t dmd_set_nvram(const uint8_t nvram[8192]);
int32_t dmd_get_nvram(uint8_t nvram[8192]);

int32_t dmd_get_pc(uint32_t *pc);                /* debug */
int32_t dmd_get_register(uint8_t reg, uint32_t *val);
int32_t dmd_read_word(uint32_t addr, uint32_t *val);
int32_t dmd_read_byte(uint32_t addr, uint8_t *val);
int32_t dmd_get_duart_output_port(uint8_t *oport);

#ifdef __cplusplus
}
#endif

#endif /* DMDCORE_H */
