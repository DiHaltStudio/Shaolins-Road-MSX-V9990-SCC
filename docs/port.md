# The MSX1 + V9990 port

Status: **playable**. The whole arcade program runs, translated to Z80, on an
MSX1 with a GFX9000 (V9990) cartridge: title, attract demo, ranking, game start,
the five stages, bosses, death, game over, with the arcade music and effects
(SCC + PSG, or PSG alone).

    make port          # build build/port/shaolins_v9990.rom (1 MiB, Konami SCC mapper)
    make run           # play it in openMSX (Sony HB-10P + GFX9000)
    make run-turbor    # the same on a turbo R (Panasonic FS-A1GT + GFX9000)
    make test          # automatic soak test (openMSX on display :99): PASS / FAIL

At power-on the boot looks for the V9990 (register 15 keeps what is written;
without one the port reads $FF) and says so in SCREEN 0, with the BIOS (still on
page 0 then): "KONAMI 1985 / DIHALT STUDIO 2026 / V9990 found !" for 2 s, or, with
no V9990, the first two lines and "V9990 NOT found!!!" on the last line, and it
stops there. Then the DiHalt logo is shown for 4 s (it cannot be skipped), then the
cover until a key or a joystick direction/button is pressed, or for 10 s.

Controls: cursor keys or joystick 1; SPACE / Z / trigger A = kick;
M / X / trigger B = jump. Start: 1, SPACE or trigger A = one player in
hard mode; 2 or trigger B = one player in medium mode (the title says
"1 HARD 2 MEDIUM"). SPACE and the triggers start only from the attract mode (in a
game they kick and jump). There are no coins or credits: a game can always be
started. Fixed settings (no DIP switches): 3 lives, extra life at 40000 and every
80000, upright cabinet, demo sounds on.
A start is taken on the press (reported for 4 frames), not while held, so a
kick still held when the attract mode comes back does not start a new game.
SPACE and the triggers are starts only outside a game: in the name entry of the
ranking (where START ends the entry) they only kick, to accept the letters.

The controls behave like the arcade lever: a reversal with no neutral frame in
between (easy on a keyboard) gets one. The original game only restarts the walk
animation on a new press, so without it the player walks backwards (also in MAME
with the same input). With both directions pressed, the last one pressed wins.

## How it is built

```
arcade data: disasm/ann/*.ann + ROM ──dis6809.py──> analysis (code, data, symbols)
                         tools/xlat6809.py ──> build/port/xl_code.asm   translated code (chunks)
                                               build/port/xl_data_p*.asm arcade data at its addresses
arcade build/gfx (decoded) ──tools/port_assets.py──> rotated patterns, sprite atlas, palettes
src/boot.asm, runtime.asm + the above ──tools/build_port.py──> main.asm ──sjasm──> ROM
```

### Translation (`tools/xlat6809.py`)

Static, instruction by instruction, from the symbolic disassembly. The arcade
data (the program ROM, the MAME coverage, the annotations, the decoded graphics
and the sound captures; see the README) is read from the directory `$ARCADE`
and is not part of this repository.

* Registers: A→A, B→B, D→A:B, X→IX, Y→IY, U→DE, S→SP; C, H, L are scratch.
* Memory is identity mapped and big-endian: the arcade RAM, tile RAM and data
  keep their addresses, 16-bit values are read high byte first.
* Flags: a liveness analysis over the control flow finds which 6809 flags are
  read later; only those are synthesised (N/Z after loads, carry kept through
  logic operations, signed branches from S xor V or from S alone when the flags
  come from a load/logic instruction).
* Auto-increment loads into the same register (`ldy ,y++`, used to follow the
  "next record" pointer of the animation tables) keep the loaded value, as on
  the 6809: the increment is not applied.
* 8-bit pushes are byte-exact (`push af / inc sp`), so stack-relative byte
  accesses work. The one routine that plays with return addresses on the stack
  (`bin_to_bcd`) is replaced by hand-written code.
* Arcade I/O: stores to the scroll and palette bank registers become stores to
  `io_scroll` / `io_palbank`; input ports read `io_*` variables (a read of a
  DIP switch is a translation error: there are none); watchdog, sound chips and
  the control latch are ignored. The build stops if an instruction could not be
  translated.
* Stores that can hit the tile RAM (found with MAME, a MAME Lua script that records the writers,
  plus every store with a 16-bit offset) call `xl_mark`, which flags the cell
  for the V9990 (HUD cells only when their value changed): a bit in a 4-byte
  mask per hardware row, and the row in a list of dirty rows, so that the
  presentation only visits what changed.
* Excluded: the NMI sound driver, the service mode and the boot test.
* Features of the cabinet that the port does not have are cut out of the
  translation (`EXCLUDE`/`SKIP`/`OVERRIDE`): the DIP switch decoding is replaced
  by fixed settings at `init_game` (3 lives, extra life at 40000 then every
  80000); the difficulty comes from the start button: START1 (key 1, SPACE,
  trigger A) sets the base level 6 = hard, START2 (key 2, trigger B) sets 4 =
  medium (`OVERRIDE` $6375 and $6393 write `difficulty`; the arcade's DIP
  difficulties were 0, 4, 6 and 10), and both start a one player game; the title
  says "PRESS START / 1 HARD 2 MEDIUM" (the text of "ONE PLAYER ONLY" is
  patched). No coins (coin counters, coin inputs, credits, the credit line, the
  credit checks of the attract mode); the port is one player: the arcade's two player code
  (score swap, "2P" line, PLAYER TWO) is still in the translation, but never
  runs); no service mode (`game_mode` 3); no flip screen and no cocktail
  cabinet (`set_flip`, `spr_flip_update`, player 2's controls); sounds always
  on in the attract demo; no crosshatch test grid at power-on.
* Overrides (`OVERRIDE`/`SKIP` in the translator): `bin_to_bcd`, the sprite list
  copy and build, the camera shift of the 24 actor slots and the boot delays,
  the screen clear, the stage map drawing and the column streaming, and three
  routines that are hot in a busy stage: the platform search (`find_floor_at`,
  with a per-stage table y -> first record of the fitting floor height), the
  enemies-left gauge (redrawn by the arcade every frame: here a cell is stored
  and marked only when it changes) and `get_level_params` (a table instead of
  `mul`), replaced by hand-written Z80 in `src/runtime.asm`.

The translated code is about 34.5 KiB (1.54x the 6809 code), split in chunks
at unconditional jumps and placed in the free space around the arcade data
by `tools/build_port.py` (first fit, page by page).

### Memory map (Z80)

| Range | Contents |
|---|---|
| `$0000-$17DF` page 0 RAM | runtime: interrupt, translator helpers, V9990 presentation, inputs, sound player, palettes |
| `$17E0-$1BFF` | translated code chunks |
| `$1C00-$1FFF` | boot stack |
| `$2000-$27FF` | dirty masks and rows, screen hold flags (`$20A1`), floor table (`$2100`), runtime variables, sprite buffers, sprite cache tables |
| `$2800-$3FFF` | arcade RAM as on the board; the gaps `$2C00`/`$3400` hold the tile shadows |
| `$4000-$7FFF` ROM bank 0 | boot, arcade data `$6000-$7FFF` at its addresses, code chunks |
| `$8000-$BFFF` ROM bank 1 | arcade data at its addresses, code chunks |
| `$C000-$FFEF` page 3 RAM | arcade data `$C000-$FFEF` (copied from bank 3), code chunks, sprite cache tables `$E600-$F4FF` |

The ROM uses the Konami SCC mapper (Konami5, 8 KiB banks; the program switches
only page 2, as two 8 KiB banks). At boot an SCC is looked for: first the one
of this cartridge (`$3F` written to `$9000` maps the SCC registers at `$9800`),
then every other slot and subslot (a slot whose `$9800` is already writable, such
as RAM, is skipped). The result is kept in `scc_slot` (`$FF` = none); the test
build `SCC_SKIP_OWN=1 make port` ignores the SCC of the cartridge.

The boot code finds a RAM slot by testing every slot, puts RAM on page 0
(the BIOS is not used after boot), copies banks 2 and 3 to RAM and uploads
all tile patterns to the V9990.

### V9990 (P1)

* **Plane B** = playfield, with the **whole stage map in VRAM**: the 42 columns
  x 27 rows of the stage are uploaded at stage start (job 8, `xl_ov_scenery`)
  to plane B columns 8..49, rows 5..31; the arcade's column streaming
  (`scenery_stream`) is skipped. Scrolling is only SCBX = cam_x + 48. The
  arcade keeps a 32-column ring in its tile RAM (hardware row r = world
  column 36 - r mod 32); its other tile writes (doors, texts) are published by
  mapping the ring row to the world column with the camera position, and are
  always published when written (no shadow: a ring row changes meaning when
  the camera moves). The ring is still filled at stage start and on every
  camera column step (without publishing), because the door and text code
  reads it back to build its tiles. The arcade's screen clear (job 0) is replaced by a direct
  blank of the whole plane B playfield. SCBY = 16 + camoff: a vertical camera
  (0..28 pixels) follows the player, because the playfield is 216 lines and
  only 188 fit under the HUD.
* Screens without the arcade score line (the title) show the arcade rows from 4
  on (the top of the "SHAO-LIN'S ROAD" logo is in row 4): plane A is scrolled by
  24 lines so that the HUD band is transparent, and SCBY = 32.
* **Plane A** = HUD, 3 tile rows (24 lines): arcade HUD rows 0+1 (merged), 2
  and 3. Opaque (its own palette block with a black that is not index 0),
  and opaque side margins hide the columns streamed in by the scroll.
* **Sprites**: 24 entries, priority P=1 (behind plane A, so the HUD covers
  them). Exception: the bird (slot 17, kind 8) flies over the arcade score rows
  (lines 0-31); it is drawn in the HUD band (3/4 of its arcade line, whatever
  the camera) with P=0, in front of the HUD as in the arcade, once it is clear
  of the opaque side margins. The rock it carries (slot 18, kind 9) hangs 12
  lines under the bird as drawn; once dropped it falls from there in a straight
  line to the top of the playfield (screen line 24), which it reaches when its
  arcade position does (that depends on the vertical camera), and then follows
  its playfield position, with P=0 away from the margins (`rock_y`). During the "GUTS!" sequence
  (`guts_timer` <> 0) the player's pose (slots 0-4) and the bonus digits (slots
  19, 20) are in front of every plane, the digits just under the HUD band (in
  the arcade they are just under the score rows). Patterns come from a cache of 256 SGT slots filled from a 3072-pattern
  atlas in ROM (code x flip x colour groups 0-2, rotated and colour-baked).
  The other colour groups (3-15: flashes, grey enemies, ...) change which
  pixels are transparent, so they cannot be approximated with group 0: they
  go through `xcache` (16 entries in page 3) and are recoloured at upload from
  a raw atlas (code x flip, pixel values) with the sprite lookup PROM
  (`slut_groups`). Measured in a 46 s game session: groups 4, 5, 6, 7, 10,
  12, 13 and 14 appear.
* **Patterns**: all 512 arcade tiles, rotated, with the needed flip and colour
  variants, uploaded at boot (5632 for plane B, 1024 for plane A).
* **Palettes**: block 0 = tiles of the current palette bank, block 1 = the
  same for the HUD with an opaque black, block 2 = the fixed sprite colours.

### Intro (`boot.asm`, `tools/intro_assets.py`)

Before the game the V9990 shows two bitmaps in BD8 mode (its 256 fixed RGB332
colours, pixel = GGGRRRBB): `assets/intro/dihalt_logo-b1.png` (256x212, already in
those colours) in B1 for 4 s, then `assets/intro/opening.png` scaled to 424 lines (square pixels,
332x424), dithered to RGB332 and centred in B3 (512x424 interlaced). Both are RLE
streams in the last ROM banks (10 banks, ~160 KiB). The logo is decoded at VRAM
$40000 and shown there with SCAY = 1024; the cover is decoded at VRAM 0 while the
logo is on screen, so it appears at once. Frames are counted with the V9990
vertical blank flag (interrupts are off at that point). The cover waits for any
key of the keyboard matrix or any direction/button of either joystick port, at
most 10 s, then for the key to be released (at most 0.5 s), so that it does not
reach the game as a coin or start. Then the V9990 is set up for P1 (`v9_init`).

### Sound

The arcade driver is not translated. Every sound of the service-mode sound test
was captured from the real driver in MAME (a MAME script that plays every sound of the sound test,
with a MAME of December 2024 or newer: older ones run the sound NMI 9 times per
frame instead of 8) and packed by `tools/sound_pack.py` into event streams sampled
at the MSX frame rate (ROM banks 49-53, ~65 KiB), with the loop points measured on
the captures. `src/sound.asm` plays them once per frame from the interrupt:

* commands come from the translated arcade code (`snd_irq_tick` -> `snd_cmd`
  `$2830`), with the driver's rules: effects `$0C`/`$15` and music 9 (game start)
  are not interrupted;
* a tempo command after a stage theme (damage 3, time warning) switches to the
  fast capture of that theme; during music 9, which goes on with the stage 1 theme,
  the fast theme takes over at the same place (seek table every 32 frames);
* with an SCC: music voices on SCC channels 1-4 (square waves; a frequency is
  written only when it changes, as a write restarts the waveform), effects on the
  PSG (two tones + noise). Without: melody and bass on PSG A/B, effects on C.
* the SCC of another slot is reached by switching page 2 (and the subslot) from
  the page 0 code, with the interrupts off.

Only frames where a voice changed (a minority: most frames only count a wait)
write the chips, with straight-line code. Cost: about 0.3 ms per frame with the
music alone, 0.6 ms with effects.

### Title and ranking

`DATA_PATCH` in the translator changes arcade data: the default ranking names
(MSX, BTV, DI, HLT, KON, AMI for the first six entries) and the title texts, one
game row higher than in the arcade. The "Konami" logo and the copyright are
shared with the ranking screen, where there is no room to move them: the title
prints its own copies (`txt_title_logo`, `txt_title_copyright` in the runtime)
and the line "MSX V9990 DIHALT 2026" under them (`txt_title_credit`), through
the text table entries of texts the port does not use (6 deposit coin, 8 RAM
check, 9 ROM check) and its list of jobs (`d_title_jobs`).

### Screen changes

When a new screen is built (the screen clear, job 0, or the stage map upload,
job 8) the display is switched off (`screen_off`, backdrop black) and switched on again by the
presentation (`present_hold`) once the jobs are done, the tiles published, the
map uploaded and the vertical camera on its target (8 to 30 frames); while it is
off the camera goes straight to its target. So no half-drawn screen and no
camera slide are seen (start of the demo, of a stage, title after a game).

`clear_actors` (all actor slots and the sprite shadow cleared, used between
screens) also disables the V9990 sprite entries: states that do not build
sprites (the "START" screen) no longer show the last ones of the demo.

While "GAME OVER / PLAYER ONE" is shown (flag set where the arcade prints it,
cleared with the actors), a sprite over its two lines (arcade lines 96-119,
screen X 66-167 for any camera) is parked, so the message is never covered.

### Frame

The V9990 vertical-blank interrupt runs `irq_entry`: it publishes the
previous frame (scroll, palette, the 24 sprite entries, up to 40 changed tile
cells), reads the keyboard/joystick, then runs one tick of the translated
arcade IRQ handler with interrupts enabled. The tick first moves the vertical
camera, then `build_sprites` writes the final V9990 sprite entries (screen Y
with the camera, parked sprites, the bird in the HUD band), so that the
presentation sends them with a single `otir`. If a tick is still running at
the next vertical blank, that interrupt only publishes and records a tick
owed; when the tick ends, up to two owed ticks are run at once, so the game
speed is kept on average.

Measured in the demo (openMSX, 8 s of the busiest scene): presentation 1.3 ms
per frame (sound included), 60 game ticks per second. In stage 1 with four or
five active enemies (the heaviest scene measured): game tick 11.7 ms,
presentation 1.3 ms, sound 0.65 ms, 82% of the frame.

## Testing

`make test` runs `tools/openmsx/test.sh`: three soak runs in parallel (random
play; two of them with `SOAK_FAST`, which keeps the player alive and leaves one
enemy per stage, so they go through every stage, the bosses, GUTS! and the
second loop), checked by `tools/openmsx/check_soak.py` (frame counter stopped,
untranslated code reached, game state out of range): PASS or FAIL. The soak only
changes the game state between game ticks (a change in the middle of a routine
can make it run away).

All emulator runs are muted, unthrottled, use the X display `$TEST_DISPLAY`
(default `:99`) and isolated openMSX settings:

| Script | Use |
|---|---|
| `tools/openmsx/test.sh` + `check_soak.py` | `make test` |
| `tools/openmsx/run_soak.sh` | minutes of random play, a stage can be forced |
| `tools/openmsx/timing.sh` | `make timing`: interrupts, ticks and presentation time per second |
| `tools/openmsx/profile.tcl` + `tools/profile_report.py` | statistical PC profile |
| `tools/openmsx/run_shots.sh` | timed screenshots and key presses |
| `tools/openmsx/run_bptrace.sh` | breakpoint logger (registers + stack) |

The user manual (`make manual`, `docs/manual/`, English and Spanish) uses screenshots
(`docs/img/`) taken with `tools/openmsx/manual_shots.tcl`, a soak run that saves the
first screenshot of each situation (stages, boss, GUTS!, game over, name entry).

## Next steps

* Flip variants of the HUD, title logo position.
