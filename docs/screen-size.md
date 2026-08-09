# Arbitrary screen sizes on the DMD 5620

*How the emulated terminal gets a screen that is not 800×1024, what part of the
firmware follows and what part cannot, and the rule that falls out of it.
Everything here is measured against firmware **8;7;3** — the ROM ipnx ships —
and cross-checked against AT&T's own published source
([dmdmtg/5620rom](https://github.com/dmdmtg/5620rom), GPL, released by Dave
Dykstra 25 March 1994). Licensing boundary: [licensing.md](licensing.md).*

## The short version

**Boot the terminal stock and resize it while it runs.** `dmd_resize_screen()`
rewrites twenty bytes of ROM data on a live machine: no reboot, no
reallocation, no reset of the DUART, NVRAM or host connection.

**Width is free. Height must stay ≥ 983 px, so keep it at 1024.**

| | rule | why |
|---|---|---|
| width | any multiple of 32, ≥ 800 | Bitmap stride is counted in 32-bit Words; 800 is the width the ROM's 88-column text grid needs |
| height | **1024** (never below 983) | the ROM scrolls at a compiled-in text row 69 = pixel row 969 |
| ceiling | 2048×2048 | the reserve claimed above the firmware's 1 MB |

So portrait stays at the authentic 800×1024 — which is already almost exactly
an iPad's portrait aspect — and landscape widens to something like **1376×1024**
(aspect 1.34, against 4:3 = 1.33).

## The one piece of geometry that is data

The 5620 keeps its entire screen description in a single 20-byte `Bitmap`
called `display`. AT&T declares it in `src/term/bootrom.s`, in assembly, under
the comment *"The display bitmap in rom at last!"*:

```asm
	.globl	display
	.data
display:
	.word	_ramstrt		# pointer to the base of the display
	.word	25			# width	in 32 bit words
	.word	16:0,16:0		# rect.origin
	.word	16:800,16:1024		# rect.corner
	.word	0			# _null
```

It is `.data`, and on this machine `.data` is linked **into ROM** and never
copied down (`src/term/map` puts only `vitty.o(.bss)` in RAM). So this is both
the template and the live structure — **there is no RAM shadow to find**. The
namelist for `lsym.8;7;3` puts it at `0x9ca8`, and the shipped binary agrees
byte for byte:

```
0x9ca8: 00 70 00 00  00 00 00 19  00 00 00 00  03 20 04 00  00 00 00 00
        base=0x700000  width=25w   origin 0,0   corner 800,1024   _null=0
```

Every blit the firmware performs goes through a `Bitmap*`, so rewriting these
twenty bytes retargets the firmware's own output. That is the whole mechanism.

## The part that is *not* data, and never will be

`include/setup.h` computes the text grid at compile time:

```c
#define	CW	9	/* width of a character */
#define	NS	14	/* newline size; height of a character */
#define	XMARGIN	3
#define XCMAX ((XMAX-2*XMARGIN)/CW-1)     /* = 87  -> 88 columns */
#define YCMAX ((YMAX-2*YMARGIN)/NS-3)     /* = 69  -> 70 rows    */
```

and `src/term/vitty.c` — the ROM's dumb-terminal emulator — compares against
those constants in some twenty-five places, every time it wraps, scrolls,
clears or clamps the cursor. They are folded into the instruction stream.

The ROM proves it: **the short `800` occurs exactly three times in the whole
64 KB image** — once in `display` at `0x9ca8`, once inside `setup_sw` (the
setup menu), and once inside the `defont` font bitmap, where it is a
coincidence of glyph pixels. The number 87 is nowhere identifiable as a screen
width. No data patch can reach the grid.

**This is why the pre-`mux` terminal keeps its 88 columns at any screen size**,
and it is arithmetic rather than a defect: the last column's glyph spans
x = 3 + 87·9 = 786 … 794, and a 240-character feed measures its rightmost lit
pixel at **793**, at both 800×1024 and 1408×800.

The layered world does not have this problem. `src/xt/layersys/windowproc.c`
redefines the same names *per layer, from the layer's rectangle*:

```c
#undef XMAX
#define XMAX	(((P->rect.corner.x - (P->rect.origin.x +3 +XMARGIN))/CW)  -1)
```

so every `mux` layer sizes itself at runtime and gets the full screen for free.
What still needs doing is the host side — muxterm and jim carry their own
`display` from V8's `libj` (see [Remaining work](#remaining-work)).

## Where the framebuffer goes, and why RAM is not a problem

A bigger screen cannot *grow in place*. AT&T's RAM map (`doc/memmap/map3`) and
the linker script (`src/term/map`) pin everything above the screen to a fixed
address: screen memory is exactly `0x19000` at `0x700000`, then `romterm` bss
at `0x719000`, pcbs and stacks at `0x71C000`, layersys bss and `Free_RAM` after
`0x71D700`. Growing the screen runs straight through the firmware's own stacks.

So it moves, to `0x800000` — above the 1 MB the terminal believes it has. That
ceiling is structural, not a guess. `bootrom.s` sizes memory into an index and
looks the limit up in a table:

```asm
	LLSB3   &2,$MAXADDR, %r2	# memory size index from test32
	MOVW	maxaddr(%r2),%r1	# last valid memory address
```

and that table, at `0xa37c` in the shipped ROM, has exactly **two** entries:

```
maxaddr[0] = 0x00740000     (a 256 KB machine)
maxaddr[1] = 0x00800000     (a 1 MB machine)
```

The self-test can only ever store 0 or 1 there. The firmware is *incapable* of
handing out an address above `0x7FFFFF`, so the space above it can never be
allocated on top of the screen, every documented structure keeps its documented
address, and `Free_RAM` keeps its full extent.

### Why the reserve is fixed, not sized to the screen

RAM is allocated once, when the `Bus` is built, and a running WE32100 cannot
have its memory reallocated underneath it. So the emulator always carries the
worst case — 1 MB for the firmware plus 512 KB for a 2048×2048 framebuffer,
making the machine 1.5 MB — and a resize changes only *where inside that* the
screen sits. **Changing screen size never allocates**, which is what makes
resizing a running terminal safe.

The slack has a second use: if the firmware addresses rows the CRT no longer
has (see below), the writes land in our own reserve instead of anything real.

## What was measured

Test harness: `libdmd/test/resize-scope.c`. It boots with **no**
`dmd_set_screen` call at all — the machine AT&T shipped — runs the self-test to
completion, feeds text, resizes, and feeds text again.

**The resize is complete.** After `dmd_resize_screen(1376, 1024)` the same 240
characters redraw through a 43-word stride at base `0x800000` instead of a
25-word stride at `0x700000`, and the resulting ink is *pixel-identical*:

| ink band (y) | x extent | lit pixels | 800×1024 | 1376×1024 |
|---|---|---|---|---|
| 3–13 | 3…792 | 3835 | ✓ | ✓ |
| 17–27 | 3…793 | 3878 | ✓ | ✓ |
| 31–43 | 3…587 | 2918 | ✓ | ✓ |

A wrong stride would smear the rows diagonally. It does not. The CPU keeps
running across the change (PC stays inside the documented `0x5354`–`0x5389`
idle window).

**Height is the constraint.** Feeding 90 paced lines, enough to drive the
terminal past its compiled-in scroll point:

| screen | lowest ink row | rows with ink | verdict |
|---|---|---|---|
| 1376×1024 | y = 981 | 772 | scrolls correctly — 969 < 1024 |
| 1408×800 | y = 503 | 396 | **broken** — scroll blits get clipped and the text collapses into the upper half |

The ROM scrolls when the cursor passes text row 69, i.e. pixel row
69·14 + 3 = **969**. A screen shorter than 983 px leaves the firmware blitting
rows the CRT does not have; `display.rect` clips them, the scroll copies less
than it should, and the visible text degrades. Nothing crashes — the writes
stay inside the reserve — but the terminal is unusable.

Hence: **widen, never shorten.**

## The self-test must run at 800×1024, and you must wait for it

This cost two wrong fixes, so it is written down plainly.

**The power-on self-test cannot run at a relocated framebuffer.** It draws each
stage's name through `display` with `F_XOR`, but it blanks and scribbles on
screen memory at a **hardcoded `0x700000`** — seven times in `selftest.c`,
including the RAM tests. Move the framebuffer and the text still lands on the
visible screen while every clear misses it, so the stage names accumulate on
top of one another and the power-on screen is unreadable mush.

So the terminal powers on stock and is resized afterwards — which is also why
the checksum repair is off the boot path.

**Waiting for "the screen stopped changing" is not good enough.** `selftest.c`
draws `"WAITING FOR KEYBOARD STATUS"` and then blocks in `t_kbd()`:

```c
	lit_draw("SHORTRAM TEST");
	shortram();
	if(which == 0)
	{
		lit_draw("WAITING FOR KEYBOARD STATUS");
		if(t_kbd() == 3) {
```

The screen is perfectly still in the *middle* of the self-test. Resizing there
pulls the framebuffer out from under every later hardcoded clear, and the
terminal never finishes booting — it sits on that message forever.

The sound signal is the firmware's **own idle loop**, `0x5354`–`0x5389`. A
firmware still polling the keyboard is not in it. Measured with
`libdmd/test/resize-scope.c` at 2× on this ROM:

| event | when |
|---|---|
| last self-test draw | 0.65 s |
| **PC first enters the idle loop** | **1.15 s** |
| longest quiet gap *during* the self-test | 0.35 s |

So the PC test separates "finished" from "waiting" cleanly where no timer can.
The app samples it three times in a row before resizing.

## 127 columns: the text grid *is* reachable

The grid is compiled in, but not out of reach. On the WE32100 a byte immediate
is the two-byte sequence `6F <value>`, so `XCMAX` appears as `6F 57` and
`XCMAX+1` as `6F 58`. Rewriting those retargets every comparison in place:
**24 operands**, and the terminal keeps running across the change.

Verified end to end — 240 characters wrap at x=1144 instead of 793, and in the
app a 125-character shell line occupies one row where it used to take two.

**127 is a hard ceiling.** The operand is one byte and the WE32100
sign-extends it, so 128 would compare as negative and the terminal would wrap
on every character. Past that needs a halfword immediate, which is a longer
instruction, not an in-place edit. A screen wider than 1158 px therefore keeps
a right margin in the ROM terminal — `mux` layers still use the full width.

The patch substitutes from the *currently applied* count, not from the ROM's
original 87/88, so a second resize still finds its operands. `Dmd::reset`
returns it to 88 with the fresh image.

### And the reserve must stay off the bus until then

The self-test **sizes memory by probing it** and stores the result as an index
into that two-entry `maxaddr` table. If the reserve above 1 MB answers while
the probe runs, the firmware decides it has more than a megabyte, indexes past
the end of the table, reads `0x0000000a` as its last valid address and wedges.
So `ram_visible()` keeps the reserve undecoded until a custom screen exists —
allocated the whole time, but not on the bus.

## Two sizes, and why not a range

The app offers exactly two screens, and the reason is that both ends of the
range are pinned by the firmware:

| | | |
|---|---|---|
| **Original** | 800×1024 | the real tube, 88 columns |
| **Wide** | 1152×1024 | 127 columns — as wide as the grid can be driven |

Height cannot move (`YCMAX` is compiled in; the ROM scrolls at pixel row 969),
and width stops being useful past 1152 (127 columns × 9 px + margins = 1149).
Everything between 800 and 1152 is a shape nothing benefits from, and offering
it only bought edge cases: the geometry became a function of the window, so a
window drag rebuilt the emulated machine, and *when* in the boot sequence the
drag landed changed the result.

So the CRT is chosen once per session, the window is shaped to it and locked to
that aspect, and resizing only scales the picture. Nothing calls
`dmd_resize_screen` in response to layout any more.

The patching is still done at **runtime**, not by shipping two prebuilt ROM
images. It would be easy to bake two ROMs, but the firmware in the app binary
would then be modified AT&T code rather than the bytes dmd_core ships — a
worse licensing position for no functional gain ([licensing.md](licensing.md)).

## The screen survives a restore; the session does not

The 5620 always power-cycles — there is no way to resume a WE32100
mid-instruction — so a restored VAX faces a terminal that has forgotten
everything on screen, and neither getty nor a shell repaints unasked. The app
now writes the framebuffer to `screen.bin` at quit and paints it back with
`dmd_set_video_ram()` once the terminal has booted. The file is raw 1-bit rows
with no header, so its length *is* its geometry check: a mismatch is discarded,
because a screen unpacked at the wrong stride is worse than a blank one.

**Verified**: quit mid-session and relaunch, and the screen comes back exactly
as it was.

**Still open** — the restored session is *mute*. The picture is right, but
nothing typed reaches V8 and nothing comes back. This is the older "mute DZ
line after restore" symptom, and it is not the `lp->rcve` fix missing: that
patch is present in the checkout and the xcframework was built after it. So
the screen snapshot fixes the cosmetic half and the input half is still to
find. Workaround: **Machine ▸ Restart Terminal**, which drops carrier and makes
getty start over.

## Remaining work

- **App plumbing.** The 800/1024/102400/100 constants are still hardcoded in
  `Terminal5620`/`FrameStore`, `FramebufferView` (Metal texture + `bytesPerRow`),
  `Shaders.metal` (needs a size uniform), `Blit5620View.pixelScale` and
  `Settings.screenSize(fitting:)`. Call `dmd_resize_screen` on orientation and
  window-size change, and re-read `dmd_video_ram()` afterwards — both the
  pointer and the length move.
- **muxterm and jim.** They carry their own `display` from V8's `libj`
  (`src/lib/j/display.c`, `{0x700000, 25, 0,0, XMAX, YMAX, 0}`). Either rebuild
  them inside V8 with new `XMAX`/`YMAX`, or patch the same 20-byte structure in
  the `/usr/jerq/lib/muxterm` and `jim` binaries — the technique that works on
  the ROM works on them.
- **The ROM's 88 columns before `mux`.** Only fixable by patching immediates in
  the instruction stream, or by rebuilding the firmware — which is the GPL
  decision recorded in [licensing.md](licensing.md) and deliberately not taken.
