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

so every `mux` layer sizes itself at runtime and gets the full screen for free —
and so does every program *running in* a layer, because `mux.h` makes `display`
a pointer rather than an object. The one program that still needs widening by
hand is `muxterm` itself, which owns the screen rather than borrowing a layer
of it (see [Remaining work](#remaining-work)).

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

### And the session survives too — but only if the terminal asks

The screen snapshot fixed the picture and left the session apparently *mute*:
nothing typed reached V8, nothing came back. It looked like the old "mute DZ
line after restore", so that was checked first and ruled out — the `lp->rcve`
patch is present in the checkout and the xcframework was built after it. Two
more independent checks then narrowed it to the app:

- `tools/restore-exec-probe.py` restores a snapshot with the app's exact
  `resume.conf` and drives the DZ line from a plain socket. `echo one` → `one`,
  `/bin/echo three` → `three`, `pwd` → `/`, and a fresh console login reaches
  the MOTD. **SIMH's restore is healthy.**
- `libdmd/test/keyboard-scope.c` measures the direction nothing had ever
  measured — `dmd_keyboard_rx()` in, `dmd_rs232_tx()` out — across a resize and
  the 24-operand column patch. Five bytes in, five bytes out, at every stage.
  **The widened terminal is healthy**, and the column rewrite lands nowhere
  near the serial path.

That left two faults, one in SIMH's restore and one in the app, and they had
been hiding each other.

**The restored machine had no disk.** `restore` re-attaches every saved unit in
device order, to the filename in the snapshot — and for the DZ that "filename"
is the *previous launch's port*, which the terminal connection that was live a
moment ago still holds in TIME_WAIT (tmxr binds without `SO_REUSEADDR`). The
bind fails. Survivable on its own; scp.c's loop is not:

```c
for (j = 0; j < attcnt; j++) {
    if ((r == SCPE_OK) && (!dont_detach_attach)) {
        ...
        r = scp_attach_unit (dptr, attunits[j], attnames[j]);
```

`r` is never reset, so the first failure skips every remaining attach — and the
DZ precedes RP0. The machine resumed with the kernel in memory and no
filesystem: the console answered, the shell even echoed `# ` from memory, and
nothing that touched the disk worked. `tools/restore-attach-probe.py` holds the
saved port so the failure is deterministic and prints the two outcomes side by
side — `RP0 ... not attached` against `attached to mutep.disk`. The fix is
`restore -D -Q` with the disk attached beforehand; the DZ still has to be
attached *after* the restore, because `dz_attach`'s `lp->rcve`/DTR fixup only
runs when CSR_MSE is already set.

**And nothing asked the far end to speak.** This is a fact about the far end
rather than about any device: **getty prints its banner and `login:` exactly
once**, when it starts, then blocks in `getname()`; a logged-in shell prints
nothing unasked at all. A cold boot gets its prompt for free because getty is
starting anyway. A restored session never does — the terminal's own CR nudge is
the only thing that can make it speak. And that nudge was:

1. sent only in the branch where *no* screen was restored, so a session that
   restored its picture never asked;
2. inside a block conditional on the screen needing a resize, so at the
   Original preset the whole thing — screen restore included — was skipped;
3. duplicated on a raw step count, 20M steps ≈ 1.0 s at the default 2× clock,
   which is *before* the self-test finishes at ~1.2 s. V8 answered into a
   terminal that was still testing itself.

All three are now one block, gated on the firmware reaching its idle PC window
and nothing else, and it always ends with the CR.

**How to test this and not fool yourself**: delete `screen.bin` before the
relaunch. With it in place the repainted picture and a live prompt are the same
pixels — both say `login:` — so a screenshot proves nothing, and an early run
of this test "passed" while the session was still dead. On a blank terminal,
anything that appears can only be V8 answering.

## Drawing it: the footprint filter, and what Retina buys

The 5620's raster almost never lands on a whole number of device pixels. On a
1470×852 desk the Wide screen gets 877×780 points, and on a 2× panel that is
1755×1560 device pixels for 1152×1024 source pixels — 1.52× magnification, and
not a ratio anything divides evenly.

Point sampling — read the one texel under the fragment centre, which is what
the shader did originally — is visibly wrong at any such ratio. Some source
rows land in two device pixels and their neighbours in one, so a regular
pattern (mux's stipple background, a run of underscores) beats against the
sampling grid and crawls. The **Crisp** setting exists to dodge that by forcing
an integral scale, at the cost of a smaller picture.

The fix is to stop point-sampling. `fb_fragment` now area-averages the device
pixel's real footprint over the raster: it takes `texels`, the source pixels
per device pixel, computes the box the fragment covers, and weights each source
pixel by how much of it falls inside. The loop is bounded at 8×8 and is 2×2 in
practice.

Two properties make this the right trade rather than a blur:

- **It costs nothing where it does not apply.** Magnified, the box is smaller
  than a source pixel, so only fragments straddling an edge blend at all —
  everything else still resolves to a hard 0 or 1.
- **At an exact integer scale no fragment straddles anything**, so the output
  is bit-identical to point sampling. "Crisp" stays exactly as crisp as it was;
  "Fill" simply stops shimmering.

`texels` comes from `MTKView.drawableSize`, never from the layout size — on a
2× display those differ by exactly the factor that makes the difference
visible. The renderer logs the ratio once per launch (`ipnx: 5620 … into a …
drawable`), which is how you check the drawable really is at native scale
rather than assuming `autoResizeDrawable` did its job.

The screen also now sits in a bezel: a fixed 10 pt graphite surround with a
hairline where the glass meets it. It is there to give the raster a physical
edge, and to keep the app's own controls — which used to be a strip inside the
black field, wrapping at the Original preset's width — out of the picture
entirely. On the Mac they are a real `NSToolbar` in the title bar, which is
also why `shapeWindow` measures chrome with `contentLayoutRect` now:
`contentRect(forFrameRect:)` answers from the style mask alone and never knows
about a toolbar.

## Remaining work

- **muxterm — done and driven** *(2026-08-10; this bullet used to say "muxterm
  and jim", and that was wrong — see below.)* `tools/widen-jerq.exp` copies
  `/usr/jerq/lib/muxterm` to `muxterm.w` and rewrites the same 20-byte `Bitmap`
  the ROM patch rewrites, at file offset 50512, exactly one hit:

  | field | stock | widened |
  |---|---|---|
  | `base` | `0x700000` | **`0x800000`** |
  | `width` (32-bit Words) | 25 | 36 |
  | `rect.corner.x` | 800 | 1152 |

  Selection uses AT&T's own hook: `mux` honours `$MUXTERM`
  (`jerq/src/mux/mux.c`), so `/usr/jerq/bin/wmux` is a three-line wrapper and
  the stock binaries are untouched. Driven end to end by
  `tools/drive-widemux.sh`, which boots the image on the desktop SIMH and runs
  `tools/dmdbridge` against it with a resized screen; measured on the
  resulting framebuffer:

  | | rightmost lit pixel | lit pixels |
  |---|---|---|
  | stock `muxterm` at 1152 | x = 648 | 22,589 |
  | `muxterm.w` at 1152 | **x = 1151** | 220,167 |

  ### `base` is the field that matters, and it is silent when wrong

  The first attempt patched only the stride and the corner, and it crashed —
  which was luckier than what the *control* did. A resized screen does not keep
  its framebuffer at `0x700000`; it cannot (see above), so dmd_core moves it to
  `0x800000` and retargets the ROM's Bitmap there. muxterm carries its own
  copy, and with `base` left at `0x700000`:

  - **Stock muxterm on a wide screen draws perfectly into memory nobody is
    looking at.** The download completes — all 55,156 bytes, the documented
    figure — mux is running, and the screen still shows the ROM terminal's last
    text. It presents as a hang and is nothing of the kind. This is what the
    control run above measured at x = 648: leftover `login:` text, no desktop.
  - **Widened muxterm with the old base is worse**: a 36-word stride from
    `0x700000` spans 144 KB, straight through `romterm` bss, the pcbs and the
    stacks at `0x719000`+, and the firmware runs away and faults.

  So: **on a resized screen, `mux` must be `wmux`.** Plain `mux` is not merely
  narrow there — it is invisible. The stock binaries still must not be patched,
  because `muxterm.w` hardcodes `0x800000` and is wrong at the Original preset,
  where the framebuffer is back at `0x700000` and the reserve is undecoded.

  Two dead ends recorded so they are not re-run: the fault address is always
  exactly `RAM_BASE + ram_visible()`, which looks like a decode-window bug and
  is not — widening `ram_visible()` to the whole reserve just moves the fault
  from `0x824000` to `0x880000`. `ram_visible()` is correct as it stands.

- **jim needs nothing, and cannot be patched.** The assumption that it carries
  its own `display` was wrong. `3nm` settles it:

  ```
  muxterm:  display    | 7514000|extern|                |    | |.data
  jim.m:    Jdisplayp  |   12660|extern|  *struct-Bitmap|  20| |.data
  ```

  jim has no `display` object — it has a *pointer*, because
  `jerq/include/mux.h` says

  ```c
  extern Bitmap *Jdisplayp;
  #define display (*Jdisplayp)
  ```

  so every layer client resolves `display` at runtime to the Bitmap its layer
  was handed, which `mux` computes from the layer rectangle — the same
  mechanism as `windowproc.c`'s per-layer `XMAX`/`YMAX` above. jim therefore
  follows a resized screen for free. muxterm is the outlier precisely because
  it *is* the layer system: it replaces the ROM terminal and owns the screen,
  so it is the one program that carries a real Bitmap. `tools/find-bitmaps.exp`
  found no (800,1024) rectangle anywhere in `jim.m`, which is the same fact
  seen from the other side.
- **The ROM's 88 columns before `mux`.** Only fixable by patching immediates in
  the instruction stream, or by rebuilding the firmware — which is the GPL
  decision recorded in [licensing.md](licensing.md) and deliberately not taken.
