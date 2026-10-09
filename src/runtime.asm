; =============================================================================
; Shao-lin's Road for MSX1 + V9990: runtime, page 0 RAM image ($0000-$27FF)
;
; The translated arcade program (xl_code) runs on an identity memory map:
;   $0000-$27FF  this runtime (copied from ROM at boot)
;   $2800-$3FFF  arcade RAM: work RAM, sprite RAM, colour RAM, video RAM
;   $4000-$BFFF  ROM banks 0 and 1: translated code + arcade data at their addresses
;   $C000-$FFFF  RAM: arcade data $C000-$FFEF + translated code in the free space
; The arcade hardware is replaced by:
;   * the V9990 vertical blank interrupt, which calls the arcade IRQ handler
;   * io_* variables for the input ports, DIP switches, scroll and palette bank
;   * present: arcade tile RAM / sprite RAM / scroll -> V9990 P1 every frame
; =============================================================================

V9_VRAM         equ 060h        ; P#0 VRAM data
V9_PAL          equ 061h        ; P#1 palette data
V9_REGD         equ 063h        ; P#3 register data
V9_REGS         equ 064h        ; P#4 register select
V9_STAT         equ 065h        ; P#5 status
V9_INT          equ 066h        ; P#6 interrupt flags
V9_SYS          equ 067h        ; P#7 system control

; V9990 VRAM map (P1)
VR_PATA         equ 000000h     ; plane A (HUD) patterns, 1024
VR_SGT          equ 008000h     ; sprite generator table, 256 patterns of 16x16
VR_SPAT         equ 03FE00h     ; sprite attribute table
VR_PATB         equ 040000h     ; plane B (playfield) patterns
VR_PNTA         equ 07C000h     ; plane A name table (64x64)
VR_PNTB         equ 07E000h     ; plane B name table (64x64)

PAT_A_BLANK     equ 16          ; HUD blank (opaque black)
PAT_A_CLEAR     equ 1023        ; fully transparent
PAT_B_BLANK     equ 16          ; playfield blank (transparent)

; Konami SCC mapper (Konami5): 8 KiB banks, registers $5000 ($4000-$5FFF), $7000 ($6000-$7FFF),
; $9000 ($8000-$9FFF; value $3F maps the SCC at $9800) and $B000 ($A000-$BFFF). The program
; works with 16 KiB banks n = 8 KiB banks 2n, 2n+1; only page 2 ($8000-$BFFF) is switched.
KSCC_B2         equ 09000h      ; bank register for $8000-$9FFF
KSCC_B3         equ 0B000h      ; bank register for $A000-$BFFF
BANK_CODE2      equ 1           ; 16 KiB bank normally mapped at $8000

; ---------------------------------------------------------------- RAM
RT_VARS         equ 02400h
io_palbank      equ RT_VARS+0   ; written by the game (arcade $1800)
io_scroll       equ RT_VARS+1   ; written by the game (arcade $2000)
io_system       equ RT_VARS+2   ; arcade SYSTEM port, active low
io_p1           equ RT_VARS+3   ; arcade P1 port, active low
io_p2           equ RT_VARS+4
start_hold      equ RT_VARS+5   ; frames the start bits are still reported
start_prev      equ RT_VARS+6   ; start sources pressed on the previous frame
start_bits      equ RT_VARS+7   ; start bits being reported (SYSTEM bits 3, 4)
start_now       equ RT_VARS+9   ; start sources pressed this frame
io_vpos         equ RT_VARS+8
xl_sptmp        equ RT_VARS+10  ; 2 bytes: SP transfers
pal_cur         equ RT_VARS+12  ; palette bank currently in the V9990
camoff          equ RT_VARS+13  ; vertical camera 0..28
frame_no        equ RT_VARS+14  ; frame counter (sprite cache stamps)
xl_game_on      equ RT_VARS+15  ; the arcade IRQ may run
spr_next        equ RT_VARS+16  ; sprite cache clock hand
tmp_key         equ RT_VARS+18  ; 2 bytes
cell_budget     equ RT_VARS+20
game_busy       equ RT_VARS+21  ; the arcade tick is running
scby_cur        equ RT_VARS+22  ; SCBY value in the V9990
tick_debt       equ RT_VARS+23  ; game ticks owed (vertical blanks during a tick)
scc_slot        equ RT_VARS+28  ; slot id of the SCC ($FF = none), found at boot
cart_slot       equ RT_VARS+29  ; slot id of this cartridge
hud_off         equ RT_VARS+30  ; 1 = screen without the arcade score line (title)
scay_cur        equ RT_VARS+31  ; SCAY value in the V9990
shadow_vid      equ 02C00h      ; last tile code sent per cell (arcade RAM gap $2C00-$2FFF)
shadow_col      equ 03400h      ; last attribute sent per cell ($FF = unknown; gap $3400-$37FF)
spat_a          equ RT_VARS+32  ; 24 x 4 bytes ($2420-$247F)
spat_b          equ 024A0h      ; 24 x 4 bytes ($24A0-$24FF)
spat_show       equ RT_VARS+24  ; 2: buffer published by present
spat_build      equ RT_VARS+26  ; 2: buffer filled by build_sprites
dirty_rows      equ 02480h      ; 32 bytes: the hardware row is in dq_list
dmask           equ 02000h      ; 32 x 4 bytes (aligned): bit per cell of the row, 1 = dirty
dq_list         equ 02080h      ; up to 32 dirty rows (a stack: present works on the top one)
dq_count        equ 020A0h
scr_hold        equ 020A1h      ; display kept off while a screen is being built
scr_frames      equ 020A2h      ; frames since the screen was cleared
cam_settled     equ 020A3h      ; the vertical camera is on its target
go_msg          equ 020A4h      ; "GAME OVER" on screen: no sprite over it
start_btn       equ 020A5h      ; starts from SPACE / triggers (attract mode only)
spr_stamp       equ 02500h      ; 256: frame of last use of each SGT slot
spr_owner       equ 02600h      ; 256 x 2: key cached in each slot ($FFFF free)
spr_map         equ 0E600h      ; 3072: key -> SGT slot ($FF = not loaded), page 3 RAM
attr_tab        equ 0F200h      ; 256: sprite attribute -> spr_map page (flip + 4*colour), page 3 RAM
                                ;      0 for colour groups 3..15 (xcache)
xcache          equ 0F300h      ; 16 x 4: [code, attribute & $CF, SGT slot, -] (aligned)
xr_lo           equ 0F340h      ; 16: colour of each pixel value for group xr_grp
xr_hi           equ 0F350h      ; 16: the same << 4
xc_key          equ 0F360h      ; 2: attribute, code being uploaded
xc_next         equ 0F362h      ; xcache replacement hand (entry * 4)
xr_grp          equ 0F363h      ; colour group in xr_lut ($FF none)
xr_lut          equ 0F400h      ; 256: pixel pair -> recoloured pair (aligned)

; ---------------------------------------------------------------- vectors
        org 0000h
        di
        jp $
        ds 0038h-$,0
        jp irq_entry
        ds 0066h-$,0
        retn                    ; NMI not used

; =============================================================================
; Interrupt: V9990 vertical blank -> present the last frame, read the inputs,
; run the arcade IRQ handler (one game tick).
; =============================================================================
irq_entry:
        push af
        push bc
        push de
        push hl
        push ix
        push iy
        ld hl,(xl_sptmp)        ; scratch words the interrupted code may be using
        push hl
        ld hl,(btb_ret)
        push hl
        in a,(V9_INT)
        and 1
        jr z,irq_other
        ld a,1
        out (V9_INT),a          ; acknowledge VI
        call present
        call read_input
        ld hl,frame_no
        inc (hl)
        ; one arcade tick per interrupt, unless the previous one is still running:
        ; the tick runs with interrupts enabled so that a slow tick never delays
        ; the next presentation (which must happen in the vertical blank)
        ld a,(xl_game_on)
        or a
        jr z,irq_done
        ld a,(game_busy)
        or a
        jr nz,irq_late
        inc a
        ld (game_busy),a
irq_tick:
        ei
        call rt_camera_update   ; the camera of this tick (build_sprites uses it)
        call irq_handler        ; translated arcade IRQ (ends with RET)
        di
        ld a,(tick_debt)        ; vertical blanks that found the tick still running:
        or a                    ; catch up with an extra tick (at most 2 owed)
        jr z,irq_tick_end
        dec a
        ld (tick_debt),a
        jr irq_tick
irq_tick_end:
        xor a
        ld (game_busy),a
irq_done:
        pop hl
        ld (btb_ret),hl
        pop hl
        ld (xl_sptmp),hl
        pop iy
        pop ix
        pop hl
        pop de
        pop bc
        pop af
        ei
        ret
irq_late:
        ld a,(tick_debt)
        cp 2
        jr nc,irq_done
        inc a
        ld (tick_debt),a
        jr irq_done
irq_other:
        in a,(099h)             ; clear a TMS9918 interrupt, if any
        jr irq_done

; =============================================================================
; Translator helpers
; =============================================================================
xl_stub:
        ret
xl_untranslated:
        di
        jr $
xl_jphl:
        jp (hl)
xl_jpix:
        jp (ix)
xl_jpiy:
        jp (iy)

; S,Z from HL (6809 N,Z of a 16-bit load); keeps A and the carry. Uses C.
xl_tsthl:
        ld c,a
        jr c,.withc
        ld a,h
        or l
        jr z,.done
        ld a,h
        or 1
.done:  ld a,c
        ret
.withc: ld a,h
        or l
        jr z,.zc
        ld a,h
        or 1
.zc:    scf
        ld a,c
        ret

; S,Z from D = A:B; keeps A, B and the carry. Uses C.
xl_tstd:
        ld c,a
        jr c,.withc
        or b
        jr z,.done
        ld a,c
        or 1
.done:  ld a,c
        ret
.withc: or b
        jr z,.zc
        ld a,c
        or 1
.zc:    scf
        ld a,c
        ret

; D = A * B (6809 MUL): Z if D = 0, C = bit 7 of B. Keeps DE.
; Shift-and-add over the bits of the smaller operand, stopping when no bit is left.
xl_mul:
        push de
        cp b
        jr c,.ok                ; A < B: A is the multiplier
        ld e,a
        ld a,b
        ld b,e                  ; swap: A = smaller
.ok:    ld e,b
        ld d,0                  ; DE = larger operand
        ld hl,0
        or a
        jr z,.end
.l:     srl a
        jr nc,.n
        add hl,de
.n:     jr z,.end               ; no multiplier bit left (Z from srl)
        sla e
        rl d
        jr .l
.end:   ld b,l
        ld a,h
        or l
        jr nz,.nz
        ld a,h                  ; D = 0: Z = 1, C = 0
        pop de
        ret
.nz:    ld a,l
        rla                     ; C = bit 7 of B, Z unchanged (0)
        ld a,h
        pop de
        ret

; ---------------------------------------------------------------- hot routines
; Hand-written replacements of arcade routines (same effect on RAM).

; copy_sprites ($6250): the arcade copies its sprite list to the sprite RAM at
; the start of a tick. Here the list is already in V9990 form: publish the
; buffer built by the last tick and build the next one in the other buffer.
xl_ov_copy_sprites:
        ld hl,(spat_build)
        ld de,(spat_show)
        ld (spat_show),hl
        ld (spat_build),de
        xor a
        ld (02A50h),a           ; tmp0 (loop counter of the original)
        ret

; copy_map_column loop ($6A14-$6A1F): 27 cells of a column, colour = A, tile codes
; read backwards from U (DE), video RAM at X (IX). The arcade streams the column
; entering its 32-column ring every frame; the port has the whole map in plane B
; already, so the ring is only kept up to date (the door code and the colour
; writes rely on it) and nothing is published. Returns like the original (RTS at $6A20).
xl_ov_copycol:
        ld c,a                  ; attribute
        push ix
        pop hl
        ld b,27
.l:     ld a,h
        sub 4
        ld h,a                  ; colour RAM
        ld (hl),c
        add a,4
        ld h,a                  ; video RAM
        dec de
        ld a,(de)
        ld (hl),a
        inc hl
        djnz .l
        push hl
        pop ix
        ld b,a                  ; B = last tile code, as the original
        xor a
        ld (02A55h),a           ; tmp5 = 0
        ld a,c
        ret

; job_bg_clear fill ($6EBB-$6EDA): the arcade fills its 32x32 tile map with
; blank $10 / attribute B. Here: fill the arcade tile RAM, mark the HUD cells
; (hardware columns 0-4) for publication and blank the playfield of plane B
; directly (columns 6..51, rows 5..31).
xl_ov_bgclear:
        push bc
        call screen_off
        ld hl,03C00h
        ld de,03C01h
        ld bc,1023
        ld (hl),010h
        ldir
        ld hl,03800h
        ld de,03801h
        ld bc,1023
        pop af                  ; A = B = attribute
        push af
        ld (hl),a
        ldir
        ; HUD cells (columns 0-4) of every row to publish: all 32 rows in the list
        ld hl,dmask
        ld de,dirty_rows
        ld b,32
        xor a
.dr:    ld (hl),01Fh
        inc l
        ld (hl),a
        inc l
        ld (hl),a
        inc l
        ld (hl),a
        inc l
        ex de,hl
        ld (hl),1
        inc l
        ex de,hl
        djnz .dr
        ld hl,dq_list
        ld b,32
.dl:    ld (hl),a
        inc l
        inc a
        djnz .dl
        ld (dq_count),a         ; 32
        ; plane B playfield blank (rows 4-31: row 4 holds the top of the title logo)
        ld d,4                  ; row
.pr:    ld l,d
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,l
        or 6
        ld l,a
        add hl,hl
        ld bc,VR_PNTB&0FFFFh
        add hl,bc
        ld a,VR_PNTB>>16
        di
        call v9_setw
        ld b,46
.pc:    ld a,PAT_B_BLANK
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
        djnz .pc
        ei
        inc d
        ld a,d
        cp 32
        jr nz,.pr
        pop bc
        ld a,010h
        ld ix,03C00h            ; as left by the original loop (X wrapped)
        ret

; job_scenery ($7268): the arcade draws the HUD damage bar (draw_hud_frame, kept)
; and 31 map columns into its ring, one per frame. The port writes the whole
; stage map (42 columns x 27 rows) into plane B at columns 8..49, rows 5..31,
; then clears draw_busy like the original.
FLIPMASK        equ 01E00h      ; 42 x 4 bytes: rows with the mirrored attribute, per column
xl_ov_scenery:
        call screen_off
        call draw_hud_frame     ; as the original job: the "DAMAGE 1 2 3 OUT" bar
        ld a,(02AB9h)           ; stage_x2
        ld c,a
        ; ---- flip masks from d_stage_attr_cols[stage]
        ld hl,d_stage_attr_cols
        ld b,0
        add hl,bc
        ld a,(hl)
        inc hl
        ld l,(hl)
        ld h,a                  ; HL = 42 column pointers
        ld de,FLIPMASK
        ld b,42
.fm:    push bc
        ld a,(hl)
        inc hl
        ld c,(hl)
        inc hl
        push hl
        ld h,a
        ld l,c                  ; HL = row list
        ld bc,0
        push de
        pop ix                  ; IX = mask (4 bytes, cleared below)
        xor a
        ld (ix+0),a
        ld (ix+1),a
        ld (ix+2),a
        ld (ix+3),a
.fl:    ld a,(hl)
        inc hl
        cp 0FFh
        jr z,.fdone
        ld c,a
        and 07Fh
        ld b,a
        rrca
        rrca
        rrca
        and 3
        add a,ixl
        ld e,a
        ld a,b
        and 7
        ld b,a
        ld a,1
        jr z,.sh0
.sh:    add a,a
        djnz .sh
.sh0:   ld d,FLIPMASK>>8
        ex de,hl
        or (hl)
        ld (hl),a
        ex de,hl
        bit 7,c
        jr z,.fl
.fdone: push ix
        pop de
        inc de
        inc de
        inc de
        inc de
        pop hl
        pop bc
        djnz .fm
        ; ---- base attribute (bit 6 = upper tile bank) and map end
        ld a,(02AB9h)
        rrca
        ld c,a
        ld hl,d_stage_tile_attr
        ld b,0
        add hl,bc
        ld a,(hl)
        and 040h
        ld (sc_bank),a
        ld a,(02AB9h)
        add a,2
        ld c,a
        ld hl,d_stage_maps
        add hl,bc
        ld a,(hl)
        inc hl
        ld l,(hl)
        ld h,a                  ; HL = end of this stage's map
        ld bc,-(27*41)-1
        add hl,bc               ; HL = row 0 of column 0 (row i of column w = end - 27*(41-w) - 1 - i)
        ld (sc_ptr),hl
        ld a,(02AD1h)           ; ring window: world columns base .. base+31
        rrca
        rrca
        rrca
        and 01Fh
        sub 2
        ld (sc_base),a
        ; ---- 27 rows
        ld c,0                  ; row i
.row:   push bc
        ld a,c
        ld (sc_row),a           ; C is clobbered inside the row (BC = addresses)
        add a,5
        ld h,0
        ld l,a
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,l
        or 8                    ; column 8
        ld l,a
        add hl,hl
        ld bc,VR_PNTB&0FFFFh
        add hl,bc
        ld a,VR_PNTB>>16
        di
        call v9_setw
        ld hl,(sc_ptr)
        ld ix,FLIPMASK
        ld b,42
.col:   push bc
        ld e,(hl)               ; tile code
        ld bc,27
        add hl,bc
        pop bc
        push hl
        ; flip bit for row i of this column
        ld a,(sc_row)
        rrca
        rrca
        rrca
        and 3
        add a,ixl
        ld l,a
        ld h,FLIPMASK>>8
        ld a,(sc_row)
        and 7
        ld d,a
        ld a,(hl)
        inc d
        jr .fe
.fb:    rrca                    ; bit (row & 7) -> bit 0
.fe:    dec d
        jr nz,.fb
        and 1                   ; flip
        ld d,a
        ld a,(sc_bank)
        or a
        jr nz,.hi
        bit 7,e
        jr nz,.hi
        ; pattern = code + 128 * flip
        call sc_ring
        ld a,d
        rrca                    ; flip -> bit 7
        or e
        ld e,a
        ld d,0
        jr .put
.hi:    ; pattern = 4096 + (code9 - 128) + 384 * flip
        call sc_ring
        ld a,(sc_bank)
        or a
        ld h,0
        jr z,.h0
        inc h
.h0:    ld l,e
        push bc
        ld bc,4096-128
        add hl,bc
        ld a,d
        or a
        jr z,.nf
        ld bc,384
        add hl,bc
.nf:    pop bc
        ex de,hl
.put:   ld a,e
        out (V9_VRAM),a
        ld a,d
        out (V9_VRAM),a
.nosh:  inc ix
        inc ix
        inc ix
        inc ix
        pop hl
        dec b
        jp nz,.col
        ei                      ; the job runs with interrupts enabled
        ld hl,(sc_ptr)
        dec hl
        ld (sc_ptr),hl          ; next row: one byte back
        pop bc
        inc c
        ld a,c
        cp 27
        jp nz,.row
        ; drop pending playfield publications (a clear still in flight would
        ; blank the map just uploaded)
        ld hl,dmask
        ld b,32
.dd:    ld a,(hl)
        and 01Fh                ; columns 0-4 kept
        ld (hl),a
        inc l
        ld (hl),0
        inc l
        ld (hl),0
        inc l
        ld (hl),0
        inc l
        djnz .dd
        xor a
        ld (02A6Ah),a           ; draw_busy = 0
        ret
; ring cell of world column w = 42 - B (if inside the window): code E, flip D
; (0/1), row sc_row. Keeps all registers but AF.
sc_ring:
        push bc
        push de
        push hl
        ld c,e                  ; code
        ld a,d
        rrca
        rrca
        rrca
        and 020h
        ld hl,sc_bank
        or (hl)
        ld e,a                  ; attribute = bank | flip
        ld a,42
        sub b                   ; w
        ld d,a
        ld a,(sc_base)
        ld b,a
        ld a,d
        sub b                   ; w - base
        jp m,.out
        cp 32
        jr nc,.out
        ld a,36
        sub d
        and 01Fh                ; ring row r = (36 - w) mod 32
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(sc_row)
        add a,5
        or l
        ld l,a
        ld a,h
        or 03Ch
        ld h,a
        ld (hl),c               ; video RAM
        ld a,h
        sub 4
        ld h,a
        ld (hl),e               ; colour RAM
.out:   pop hl
        pop de
        pop bc
        ret

sc_ptr:  dw 0
sc_bank: db 0
sc_base: db 0
sc_code: dw 0
sc_row:  db 0

; camera_update ($68E6-$68F6): x (-12,x) += scroll_delta for the 24 slots
xl_ov_camshift:
        push af
        push bc
        ld a,(02AD3h)           ; scroll_delta
        or a
        jr z,.done              ; camera still: most frames
        ld c,a
        ld hl,03104h            ; slot 0 + 4
        ld de,32
        ld b,24
.l:     ld a,(hl)
        add a,c
        ld (hl),a
        add hl,de
        djnz .l
.done:  pop bc
        pop af
        ld ix,03410h            ; X as left by the original loop
        xor a
        ret

; clear_actors ($6C0C-$6C19): $3030-$33FF := 0 (flags, sprite shadow, every actor
; slot). The sprite shadow is not used here: the V9990 sprite entries are
; disabled instead, as nothing may rebuild them before the next screen. Leaves
; X = $3400, U = 0 as the original; keeps A, B.
xl_ov_clear_actors:
        push af
        push bc
        ld hl,03030h
        ld de,03031h
        ld bc,03400h-03031h
        ld (hl),0
        ldir
        ld hl,spat_a
        call .dis
        ld hl,spat_b
        call .dis
        xor a
        ld (bs_n_a),a
        ld (bs_n_b),a
        ld (go_msg),a
        pop bc
        pop af
        ld ix,03400h
        ld de,0
        ret
.dis:   ld b,24
.d:     ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),010h            ; disabled
        inc hl
        djnz .d
        ret

; A new screen is built: display off until it is complete (present_hold), no
; "GAME OVER" message. From the main loop (interrupts on). Uses A, C.
screen_off:
        ld a,1
        ld (scr_hold),a
        xor a
        ld (scr_frames),a
        ld (go_msg),a
        di
        ld a,15
        ld c,48
        call v9_reg             ; R#15: backdrop = palette 48, always black (block 3)
        ld a,8
        ld c,002h
        call v9_reg             ; R#8: display off
        ei
        ret

; draw_enemy_gauge ($A5E8-$A61F): enemies_left / 3 full tiles ($4F) from cell
; $3E62 towards lower rows (-32), a partial tile, two blanks. Called every frame,
; nearly always with the same values: a cell is stored (and marked) only when it
; changes. Leaves tmp0/tmp1, X, A, B, U as the original.
xl_ov_gauge:
        ld a,(enemies_left)
        ld b,0FFh
.div:   inc b
        sub 3
        jr nc,.div
        add a,3                 ; A = n mod 3, B = n / 3
        ld (tmp0),a
        ld hl,tmp1
        ld (hl),b
        ld c,a
        ld hl,03E62h
        ld de,-32
        ld a,b
        or a
        jr z,.part
        ld a,04Fh
.full:  cp (hl)
        call nz,.store
        add hl,de
        djnz .full
.part:  push hl
        pop ix                  ; X = the partial cell
        ld hl,d_gauge_tiles
        ld b,0
        add hl,bc
        ld a,(hl)
        push ix
        pop hl
        cp (hl)
        call nz,.store
        add hl,de
        ld a,010h
        cp (hl)
        call nz,.store
        add hl,de
        cp (hl)
        call nz,.store
        ld de,d_gauge_tiles
        ld b,0
        ret
.store: ld (hl),a
        push hl
        call xl_mark
        pop hl
        ret

; get_level_params ($9D4F-$9D5F): U = d_level_params + 7 * min(level_cur, $1F)
; (D = 7 * level, as the original)
xl_ov_level_params:
        ld a,(level_cur)
        cp 020h
        jr c,.ok
        ld a,01Fh
.ok:    add a,a
        ld l,a
        ld h,lp_tab>>8          ; the table does not cross a page
        ld a,l
        add a,lp_tab&255
        ld l,a
        ld e,(hl)
        inc l
        ld d,(hl)
        ld a,e
        sub d_level_params&255
        ld b,a
        xor a
        ret

; find_floor_at ($AFDC-$B01F): the platform under the point (A = y, B = x) in the
; stage's list of [floor y, x0, x1] (big-endian words, 5 bytes, y = 0 ends):
; the first record (list order) with a floor at most 12 pixels above the point and
; x in [x0, x1] in playfield coordinates. Found: A = floor y, C = 1 (B = ~tmp1, as
; the original); not found: A = 0, C = 0, B = tmp1. Below the ground line ($20)
; still counts as standing. U (DE) = the record found, or the end of the list, as
; the original. ff_tab gives, per y, the offset of the first record whose floor
; height fits (built when the stage changes): only the records of that height are
; tested.
FF_TAB          equ 02100h      ; 256: y -> offset of the first fitting record ($FF none)
xl_ov_find_floor:
        ld (tmp0),a
        ld a,(ix+4)
        cp 00Ah
        jr c,.w
        ld a,b
        add a,8                 ; bosses are wider: test 8 pixels further
        ld b,a
.w:     ld a,b
        ld (tmp1),a
        ld a,(stage_x2)
        ld hl,ff_stage
        cp (hl)
        call nz,ff_build
        ld a,(tmp0)
        ld l,a
        ld h,FF_TAB>>8
        ld a,(hl)
        cp 0FFh
        jr z,.none
        ld hl,(ff_list)
        ld e,a
        ld d,0
        add hl,de               ; HL = first fitting record
        ld a,(hl)
        ld (ff_y),a             ; its floor height: the others are skipped
        ld a,(tmp1)
        ld e,a                  ; D = 0
        ex de,hl
        ld bc,-16
        add hl,bc
        ld a,(cam_x+1)
        ld c,a
        ld a,(cam_x)
        ld b,a
        add hl,bc
        ld b,h
        ld c,l                  ; BC = x - 16 + cam_x
        ex de,hl
.rec:   ld a,(ff_y)
        cp (hl)
        jr nz,.next
        inc hl
        inc hl                  ; -> x0 low
        ld a,c
        sub (hl)
        dec hl
        ld a,b
        sbc a,(hl)
        jr c,.nx1               ; x < x0
        inc hl
        inc hl
        inc hl                  ; -> x1 low
        ld a,(hl)
        sub c
        dec hl
        ld a,(hl)
        sbc a,b
        jr c,.nx3               ; x1 < x
        dec hl
        dec hl
        dec hl
        ex de,hl                ; U = the record
        ld a,(ff_y)
.found: ld c,a
        ld a,(tmp1)
        cpl
        ld b,a
        or a                    ; Z from B, as comb
        ld a,c
        scf
        ret
.nx3:   dec hl
        dec hl
.nx1:   dec hl
.next:  ld de,5
        add hl,de
        ld a,(hl)
        or a
        jr nz,.rec
.none:  ld de,(ff_end)          ; U = the end of the list
        ld a,(tmp0)
        cp 021h
        jr nc,.air
        ld a,020h               ; nothing found, at or below the ground line
        jr .found
.air:   ld a,(tmp1)
        ld b,a
        xor a
        ret

; FF_TAB for the list of stage_x2: for each record, in reverse order (the first
; one wins), the y range [floor - 12, floor - 1] gets its offset.
ff_build:
        ld (ff_stage),a
        ld e,a
        ld d,0
        ld hl,d_floor_lists
        add hl,de
        ld d,(hl)
        inc hl
        ld e,(hl)
        ld (ff_list),de
        ld hl,FF_TAB
.clr:   ld (hl),0FFh
        inc l
        jr nz,.clr
        ex de,hl                ; HL = first record
        ld c,0                  ; offset
.cnt:   ld a,(hl)               ; push the records (offset, floor), then pop them
        or a
        jr z,.end
        push bc
        push af
        inc sp                  ; floor byte under the offset: 3 bytes per record
        ld de,5
        add hl,de
        ld a,c
        add a,5
        ld c,a
        jr .cnt
.end:   ld (ff_end),hl
        ld a,c
        or a
        ret z
.pop:   dec sp
        pop af                  ; A = floor
        pop bc                  ; C = offset
        ld l,a
        ld h,FF_TAB>>8
        ld b,12
.y:     dec l
        ld (hl),c
        djnz .y
        ld a,c
        or a
        jr nz,.pop
        ret

ff_stage:       db 0FFh         ; stage of FF_TAB
ff_list:        dw 0
ff_end:         dw 0            ; its terminator
ff_y:           db 0

; build_sprites ($8FA1) + slot_to_sprite: active slots 23..0 -> the V9990 sprite
; entries [screen Y, SGT slot, X, attribute] in spat_build, published as they are.
; Arcade hardware: X = -12,x - 7 (shown if 2..240), hw Y = $F0 - -10,x;
; screen X = arcade X - 1, screen Y = hw Y - 16 - camoff - 1 = 223 - camoff - y.
; Sprites outside the playfield (screen Y 211..239) are parked, disabled, at 216.
; The bird (slot 17, kind 8) flies over the arcade score rows: it goes to the
; HUD band, in front of plane A when clear of the side margins. The rock it
; carries (slot 18, kind 9) hangs 12 lines under the bird as shown, and falls from
; there to its playfield position (rock_y); in front of plane A as the bird.
; During the "GUTS!" sequence (guts_timer $3031 <> 0) the player's pose (slots
; 0-4) and the bonus digits (slots 19, 20) are in front of every plane; the
; digits, just under the score rows in the arcade, go just under the HUD band.
xl_ov_build_sprites:
        ld a,(go_msg)
        add a,a
        ld c,a                  ; bit 1: "GAME OVER"
        ld a,(03031h)           ; guts_timer
        or a
        jr z,.ng
        ld a,1                  ; bit 0: GUTS!
.ng:    or c
        ld (bs_flags),a
        ld de,(spat_build)
        ld a,(camoff)
        cpl
        sub 32
        ld ixh,a                ; 223 - camoff
        ld hl,033E0h            ; slot 23
        ld b,24
.l:     ld a,(hl)               ; +0 active
        or a
        jr z,.next
        set 2,l
        ld a,(hl)               ; +4 x
        sub 7                   ; arcade X
        cp 2
        jr c,.nexts
        cp 241
        jr nc,.nexts
        dec a
        ld c,a                  ; screen X
        set 1,l
        ld a,ixh
        sub (hl)                ; +6: screen Y
        ld ixl,0A0h             ; palette block 2, P=1
        push af
        ld a,(bs_flags)
        or a
        jr z,.back              ; nothing special: most frames
        pop af
        call bs_special
        push af
.back:  pop af
        cp 211
        jr c,.y
        cp 240
        jr nc,.y
        ld a,216                ; outside the playfield: parked
        ld ixl,010h
.y:     ld (de),a
        inc de
        inc l
        inc l
        ld a,(hl)               ; +8 code
        ex af,af'
        inc l
        ld a,(hl)               ; +9 attribute
        push hl
        ld l,a
        ld h,attr_tab>>8
        ld h,(hl)               ; spr_map page for this flip/colour
        inc h
        dec h
        jr z,.xc                ; colour group 3..15: small cache
        ex af,af'
        ld l,a
        ld a,(hl)
        cp 0FFh
        call z,spr_miss_game
.put:   ld (de),a               ; pattern slot
        inc de
        ld l,a
        ld h,spr_stamp>>8
        ld a,(frame_no)
        ld (hl),a
        ld a,c
        ld (de),a               ; X
        inc de
        ld a,ixl
        ld (de),a               ; attribute
        inc de
        pop hl
        ld a,l
        cp 029h                 ; slot 1, 9 or 17 (+9)
        jr z,.bird
        cp 049h                 ; slot 2, 10 or 18 (+9)
        jr z,.rock
.nexts: ld a,l
        and 0E0h
        ld l,a                  ; back to the slot base
.next:  ld a,l
        sub 32
        ld l,a
        jr nc,.nb
        dec h
.nb:    dec b
        jp nz,.l                ; (out of djnz range)
        jp build_sprites_end
.xc:    ex af,af'
        ld h,a                  ; code
        call xc_get
        jr .put
.bird:  ld a,h
        cp 033h
        jr nz,.nexts
        ld a,(03334h)           ; slot 17 kind
        cp 8
        jr nz,.nexts
.band:  push hl
        ld a,l
        and 0E0h
        or 6
        ld l,a
        ld a,(hl)               ; y
        cpl
        sub 15                  ; hardware line
        srl a
        ld l,a
        srl a
        add a,l
        dec a                   ; 3/4 of the line: the 24 HUD lines
        ex de,hl
        dec hl
        dec hl
        dec hl
        dec hl
        ld (hl),a               ; Y of the entry just written
        inc hl
        inc hl
        inc hl
.prio:  ld a,c
        cp 16
        jr c,.bp
        cp 224+1
        jr nc,.bp
        ld (hl),080h            ; P=0: over the HUD, as in the arcade
        jr .bq
.bp:    ld (hl),0A0h            ; P=1: hidden by the opaque margins
.bq:    inc hl
        ex de,hl
        pop hl
        jr .nexts
.rock:  ld a,h
        cp 033h
        jp nz,.nexts
        ld a,(03354h)           ; slot 18 kind
        cp 9
        jp nz,.nexts
        push hl
        call rock_y
        ex de,hl
        dec hl
        dec hl
        dec hl
        dec hl
        ld (hl),a               ; Y of the entry just written
        inc hl
        inc hl
        inc hl
        cp 211
        jr c,.prio
        cp 240
        jr nc,.prio
        dec hl
        dec hl
        dec hl
        ld (hl),216             ; below the playfield: parked
        inc hl
        inc hl
        inc hl
        ld (hl),010h
        jr .bq


; Screen Y of the bird's rock (slot 18). Keeps BC, DE, HL.
; Carried (state 0): 12 lines under the bird, which is drawn at 3/4 of its line
; in the HUD band. Falling: from the point where it was dropped (rk_y0, line
; rk_h0) it reaches the top of the playfield (screen line 24, arcade line
; H = 41 + camoff) at the same time as its arcade position does, in a straight
; line; from there on, its playfield position (line - 17 - camoff).
rock_y:
        push bc
        push de
        push hl
        ld a,(03346h)           ; y
        cpl
        sub 15
        ld c,a                  ; C = arcade line (hardware Y)
        ld a,(03341h)           ; state
        or a
        jr nz,.fall
        ld a,c
        sub 12                  ; the bird's line
        srl a
        ld l,a
        srl a
        add a,l
        dec a                   ; the bird in the band
        add a,12
        ld (rk_y0),a
        ld b,a
        ld a,c
        ld (rk_h0),a
        ld a,b
        jr .done
.fall:  ld a,(camoff)
        add a,41
        ld b,a                  ; B = H
        ld a,c
        cp b
        jr nc,.pf               ; at or under the top of the playfield
        ld a,(rk_y0)
        cp 24
        jr nc,.hold
        ld a,(rk_h0)
        ld d,a                  ; D = h0
        ld a,b
        sub d
        jr c,.pf
        jr z,.pf
        ld e,a                  ; E = H - h0
        ld a,c
        sub d
        jr nc,.dh
        xor a
.dh:    ld c,a                  ; C = line - h0
        ld a,(rk_y0)
        neg
        add a,24
        ld b,a                  ; B = 24 - y0 (1..24)
        ld hl,0
        ld d,0
        push de                 ; E = H - h0
        ld e,c                  ; DE = line - h0
.m:     add hl,de
        djnz .m                 ; HL = (line - h0) * (24 - y0)
        pop de                  ; DE = H - h0
        ld c,0
.dv:    or a
        sbc hl,de
        jr c,.dq
        inc c
        jr .dv
.dq:    ld a,(rk_y0)
        add a,c                 ; y0 + (24 - y0) * (line - h0) / (H - h0)
        jr .done
.hold:  ld a,c                  ; dropped below line 24: stay there until the
        sub 17                  ; playfield position comes down to it
        ld hl,camoff
        sub (hl)
        ld hl,rk_y0
        cp (hl)
        jr nc,.done
        ld a,(hl)
        jr .done
.pf:    ld a,c
        sub 17
        ld hl,camoff
        sub (hl)
.done:  pop hl
        pop de
        pop bc
        ret

rk_y0:  db 0                    ; screen Y of the rock when it was dropped
rk_h0:  db 0                    ; its arcade line then
bs_flags: db 0                  ; bit 0 GUTS! sequence, bit 1 "GAME OVER" shown

; A = screen Y of the slot at HL (+6), C = screen X, IXL = attribute:
; GUTS! (bs_flags bit 0): pose and bonus in front of every plane, the bonus
; digits under the HUD band; "GAME OVER" (bit 1): a sprite over the two lines of
; the message (arcade lines 96-119, screen X 82-161) is parked.
bs_special:
        push af
        ld a,(bs_flags)
        rrca
        jr nc,.ng
        call bs_front
        jr nz,.ng
        ld ixl,080h             ; GUTS!: in front of every plane
        ld a,h
        cp 033h
        jr nz,.ng
        pop af
        ld a,23                 ; bonus digits: line 24, under the HUD band
        push af
.ng:    ld a,(bs_flags)
        and 2
        jr z,.done
        ld a,(hl)               ; y
        cpl
        sub 15+81               ; hardware line of the top - 81
        cp 119-81+1
        jr nc,.done             ; not on the message lines
        ld a,c
        sub 82-15-8
        cp 161+8-(82-15-8)+1
        jr nc,.done             ; beside it
        pop af
        ld a,216                ; parked
        ld ixl,010h
        ret
.done:  pop af
        ret

; GUTS! sequence: Z if HL (inside a slot) is in a slot of the pose (0-4:
; $3100-$319F) or of the bonus digits (19, 20: $3360-$339F).
bs_front:
        ld a,h
        cp 031h
        jr nz,.b
        ld a,l
        cp 0A0h
        jr .t
.b:     cp 033h
        ret nz
        ld a,l
        sub 060h
        cp 040h
.t:     sbc a,a                 ; C (in): $FF, out: 0
        inc a                   ; in: Z
        ret

build_sprites_end:
        ; disable the entries after the written ones, as far as the last build
        ; of this buffer went (the rest of it is disabled already)
        ld hl,(spat_build)
        ex de,hl                ; HL = end of the written entries, DE = buffer
        push hl
        or a
        sbc hl,de
        ld a,l
        rrca
        rrca
        and 03Fh
        ld c,a                  ; n = entries written
        ld hl,bs_n_a
        ld a,e
        cp spat_a&255
        jr z,.buf
        inc hl                  ; bs_n_b
.buf:   ld a,(hl)               ; entries of the last build of this buffer
        ld (hl),c
        pop hl
        sub c
        jr z,.done
        jr c,.done
        ld b,a
.clr:   ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),010h            ; disabled
        inc hl
        djnz .clr
.done:  xor a
        ld (02A50h),a
        ret

bs_n_a: db 24                   ; entries written by the last build of spat_a
bs_n_b: db 24                   ; and of spat_b (24 at boot: all of them)

; Map 16 KiB bank A at $8000-$BFFF (8 KiB banks 2A, 2A+1). Keeps all registers.
set_p2:
        push af
        ld (p2_cur),a           ; shadow first: the sound player restores it
        add a,a
        ld (KSCC_B2),a
        inc a
        ld (KSCC_B3),a
        pop af
        ret

; cache miss from the game tick: as spr_miss, with the uploads protected from
; the presentation interrupt and the code bank restored
spr_miss_game:
        call spr_miss
        push af
        ld a,BANK_CODE2
        call set_p2
        pop af
        ret

; 6809 bin_to_bcd ($7168): D = A:B -> 6 decimal digits (one per byte, most
; significant first) left on top of the stack for the caller, which pops them.
; Keeps IX. Uses HL, DE, BC, IY (the original also changes U and Y).
xl_bin_to_bcd:
        pop hl
        ld (btb_ret),hl
        ld h,a
        ld l,b                  ; HL = value
        ld iy,btb_buf
        ld (iy+0),0
        ld de,10000
        call .digit
        ld (iy+1),a
        ld de,1000
        call .digit
        ld (iy+2),a
        ld de,100
        call .digit
        ld (iy+3),a
        ld de,10
        call .digit
        ld (iy+4),a
        ld (iy+5),l
        ld hl,-6
        add hl,sp
        ld sp,hl                ; 6 bytes on the stack
        ex de,hl
        ld hl,btb_buf
        ld bc,6
        ldir
        ld hl,(btb_ret)
        jp (hl)
.digit: xor a
.d1:    or a
        sbc hl,de
        jr c,.d2
        inc a
        jr .d1
.d2:    add hl,de
        ret
btb_ret: dw 0
btb_buf: ds 6

; Mark the tile RAM cell at HL dirty (if HL is in $3800-$3FFF and the value
; differs from the one last sent to the V9990). Keeps AF, BC, DE. Uses HL.
xl_mark:
        push af
        ld a,h
        sub 038h
        cp 8
        jr nc,.no
        ld a,l
        and 01Fh
        cp 4
        jr nc,.mark             ; playfield cell (rows 4-31): always published (no shadow)
        push bc
        ld c,(hl)               ; new value
        ld b,h
        ld a,h
        cp 03Ch
        jr nc,.vid
        sub 4                   ; colour $38xx -> shadow $34xx
        jr .cmp
.vid:   sub 16                  ; code $3Cxx -> shadow $2Cxx
.cmp:   ld h,a
        ld a,(hl)
        cp c
        ld h,b
        pop bc
        jr z,.no                ; unchanged: nothing to publish
.mark:  push bc
        push de
        ld a,l
        and 7
        ld c,a
        ld b,0
        ld d,h                  ; DE = cell address
        ld e,l
        ld hl,bits8
        add hl,bc
        ld c,(hl)               ; C = bit of the column in its mask byte
        ld a,e
        rlca
        rlca
        rlca
        and 7
        ld b,a
        ld a,d
        and 3
        rlca
        rlca
        rlca
        or b
        ld b,a                  ; B = row = (address & $3FF) >> 5
        ld a,e
        rrca
        rrca
        rrca
        and 3                   ; column >> 3
        ld l,a
        ld a,b
        add a,a
        add a,a
        or l
        ld l,a
        ld h,dmask>>8           ; HL = mask byte (row * 4 + column / 8)
        ld a,(hl)
        or c
        ld (hl),a
        ld a,b
        add a,dirty_rows&255
        ld l,a
        ld h,dirty_rows>>8
        ld a,(hl)
        or a
        jr nz,.inlist
        ld (hl),1
        ld a,(dq_count)
        or dq_list&255
        ld l,a
        ld h,dq_list>>8
        ld (hl),b
        inc a
        and 03Fh
        ld (dq_count),a
.inlist:
        pop de
        pop bc
.no:    pop af
        ret

bits8:  db 1,2,4,8,16,32,64,128

; d_level_params + 7 * level, levels 0-31 (64 bytes, within one page)
        align 64
lp_tab:
        dw d_level_params+0
        dw d_level_params+7
        dw d_level_params+14
        dw d_level_params+21
        dw d_level_params+28
        dw d_level_params+35
        dw d_level_params+42
        dw d_level_params+49
        dw d_level_params+56
        dw d_level_params+63
        dw d_level_params+70
        dw d_level_params+77
        dw d_level_params+84
        dw d_level_params+91
        dw d_level_params+98
        dw d_level_params+105
        dw d_level_params+112
        dw d_level_params+119
        dw d_level_params+126
        dw d_level_params+133
        dw d_level_params+140
        dw d_level_params+147
        dw d_level_params+154
        dw d_level_params+161
        dw d_level_params+168
        dw d_level_params+175
        dw d_level_params+182
        dw d_level_params+189
        dw d_level_params+196
        dw d_level_params+203
        dw d_level_params+210
        dw d_level_params+217

; =============================================================================
; V9990 helpers
; =============================================================================
; Set the VRAM write address A:HL (A = bits 18-16). Keeps BC, DE, HL.
v9_setw:
        push af
        xor a
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a
        ld a,h
        out (V9_REGD),a
        pop af
        out (V9_REGD),a
        ret

; Write V9990 register A with value C.
v9_reg:
        out (V9_REGS),a
        ld a,c
        out (V9_REGD),a
        ret

; =============================================================================
; present: publish the arcade picture to the V9990 (called in the vertical blank)
; =============================================================================
present:
        call present_hold
        call present_scroll
        call present_palette
        call present_sprites
        call present_tiles
        jp sndp_frame

; scroll: plane B X = ~arcade scroll (ring of 256 pixels, duplicated in the
; 512-pixel plane), Y = 16 + camoff
present_scroll:
        ld a,(io_scroll)
        cpl
        add a,104               ; SCBX = cam_x + 48 (scroll_reg = 55 - cam_x), 8 bits: 48..160
        ld c,a
        ld b,0
        ld a,c
        and 7
        ld l,a
        ld a,23
        out (V9_REGS),a
        ld a,l
        out (V9_REGD),a         ; R#23 SCBX bits 2-0
        ld a,c
        rrca
        rrca
        rrca
        and 01Fh
        ld l,a
        ld a,b
        rrca
        rrca
        rrca
        and 020h
        or l
        out (V9_REGD),a         ; R#24 SCBX bits 8-3
        ld a,(hud_off)
        or a
        jr z,.scay
        ld a,24                 ; plane A rows 3-5: transparent, margins kept
.scay:  ld hl,scay_cur
        cp (hl)
        jr z,.scby
        ld (hl),a
        ld c,a
        ld a,17
        out (V9_REGS),a
        ld a,c
        out (V9_REGD),a         ; R#17 SCAY
        xor a
        out (V9_REGD),a         ; R#18
.scby:  ld a,(camoff)
        add a,16
        ld hl,scby_cur
        cp (hl)
        ret z                   ; SCBY is only written when it changes
        ld (hl),a
        ld c,a
        ld a,21
        out (V9_REGS),a
        ld a,c
        out (V9_REGD),a         ; R#21 SCBY
        xor a
        out (V9_REGD),a         ; R#22
        ret

; vertical camera: follow the player (slot 0 height, $3106) while a stage is played
rt_camera_update:
        ld a,(02A02h)           ; game_mode
        cp 2
        jr z,.game
        ; outside the game: screens without the score line (title) use the HUD band
        ; too: plane A scrolled to transparent rows, view from arcade row 4 (logo)
        ld hl,03C00h+2*32       ; arcade row 0, cells r = 2..29
        ld de,32
        ld b,28
.hud:   ld a,(hl)
        cp 010h
        jr nz,.hudon
        add hl,de
        djnz .hud
        ld a,1
        ld (hud_off),a
        ld b,16                 ; SCBY 32: arcade row 4 at the top of the screen
        jr .target
.hudon: xor a
        ld (hud_off),a
        ld b,4
        jr .target
.game:  xor a
        ld (hud_off),a
        ld a,(03106h)           ; player height (grows upwards)
        ld c,a
        ld a,240-16-100
        sub c                   ; screen row of the player if camoff = 0
        jr nc,.pos
        xor a
.pos:   cp 28
        jr c,.ok
        ld a,28
.ok:    ld b,a
.target:
        ld a,(scr_hold)
        or a
        jr z,.step
        ld a,b                  ; display off: straight to the target
        ld (camoff),a
.step:  ld a,(camoff)
        cp b
        ld a,1
        jr z,.set               ; on the target
        ld a,(camoff)
        jr c,.up
        dec a
        jr .mv
.up:    inc a
.mv:    ld (camoff),a
        cp b
        ld a,1
        jr z,.set
        xor a
.set:   ld (cam_settled),a
        ret

; While a new screen is built (from the screen clear, job 0, or the stage map
; upload, job 8) the display stays off: until the jobs are done, the tiles
; published, the scenery uploaded and the camera on its target (at least 8
; frames, at most 30).
present_hold:
        ld a,(scr_hold)
        or a
        ret z
        ld hl,scr_frames
        inc (hl)
        ld a,(hl)
        cp 30
        jr nc,.on
        cp 8
        ret c
        ld a,(02A6Ah)           ; draw_busy (scenery upload, screen clear)
        or a
        ret nz
        ld a,(dq_count)         ; tiles still to publish
        or a
        ret nz
        ld a,(cam_settled)
        or a
        ret z
        ld a,(02A14h)           ; cmdq_rd (big-endian): the next queued word
        ld h,a
        ld a,(02A15h)
        ld l,a
        bit 7,(hl)              ; bit 15 set: empty, no job pending
        ret z
.on:    xor a
        ld (scr_hold),a
        ld a,15
        ld c,000h
        call v9_reg             ; R#15: backdrop = palette 0 again
        ld a,8
        ld c,082h
        jp v9_reg               ; R#8: display on

present_palette:
        ld a,(io_palbank)
        and 7
        ld hl,pal_cur
        cp (hl)
        ret z
        ld (hl),a
        ; blocks 0 and 1 = 32 colours x 3 bytes from pal_banks + bank * 96
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; *32
        ld e,l
        ld d,h
        add hl,hl
        add hl,de               ; *96
        ld de,pal_banks
        add hl,de
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a         ; palette pointer = colour 0
        ld bc,96*256+V9_PAL
        otir
        ret

; ---------------------------------------------------------------- sprites
; Publish the 24 sprite entries of spat_show (final bytes, built by the game tick).
present_sprites:
        ld a,VR_SPAT>>16
        ld hl,VR_SPAT&0FFFFh
        call v9_setw
        ld hl,(spat_show)
        ld bc,06000h|V9_VRAM    ; 24 x 4 bytes
        otir
        ret


; Cache miss: HL = map entry of the key (H - spr_map/256 = flip + 4*colour,
; L = code). Returns A = the SGT slot now holding the pattern. Keeps BC, DE.
spr_miss:
        push bc
        push de
        push hl
        ld a,h
        sub spr_map>>8
        ld b,a
        ld c,l
        ld (tmp_key),bc
        call spr_alloc
        pop hl
        ld (hl),e               ; map[key] = slot
        push de
        call spr_upload
        pop de
        ld a,e
        pop de
        pop bc
        ret

; Take an SGT slot not used in the last 16 frames (clock hand), evict its
; previous owner (spr_map + owner key := $FF) and give it to tmp_key.
; Returns E = slot. Uses A, BC, D, HL.
spr_alloc:
        ld a,(frame_no)
        ld c,a
        ld a,(spr_next)
        ld e,a
        ld d,spr_stamp>>8
        ld b,0
.find:  ld a,(de)
        neg
        add a,c                 ; frames since the slot was last used
        cp 16                   ; used in the last 16 frames: keep it
        jr nc,.got
        inc e
        djnz .find
.got:   ld a,e
        inc a
        ld (spr_next),a
        ld l,e
        ld h,0
        add hl,hl
        ld bc,spr_owner
        add hl,bc
        ld c,(hl)
        inc hl
        ld b,(hl)
        ld a,b
        cp 0FFh
        jr z,.free
        push hl
        ld hl,spr_map
        add hl,bc
        ld (hl),0FFh
        pop hl
.free:  ld bc,(tmp_key)
        ld (hl),b
        dec hl
        ld (hl),c
        ret

; Sprites of colour groups 3..15 (rare: flashes, some enemies) are not in the
; baked atlas. They are recoloured from the raw atlas when uploaded and found
; through xcache, 16 entries [code, attribute & $CF, SGT slot, -]. The owner
; key of such a slot is the address of the entry's slot byte minus spr_map, so
; evicting the slot marks the entry empty.
; In: H = code, L = attribute. Out: A = SGT slot. Keeps BC, DE.
; Called from the game tick only (restores the code bank at $8000).
xc_get:
        push bc
        push de
        ld d,h
        ld a,l
        and 0CFh
        ld e,a                  ; D = code, E = key attribute
        ld hl,xcache
        ld b,16
.s:     ld a,(hl)
        cp d
        jr nz,.n
        inc l
        ld a,(hl)
        cp e
        jr nz,.n1
        inc l                   ; HL = slot byte
        ld a,(hl)
        cp 0FFh
        jr z,.fill              ; evicted: load it again in this entry
        pop de
        pop bc
        ret
.n1:    dec l
.n:     ld a,l
        add a,4
        ld l,a
        djnz .s
        ; replace an entry (round robin, skipping the ones shown in the last
        ; 2 frames when possible)
        ld a,(frame_no)
        ld c,a
        ld b,16
.v:     ld a,(xc_next)
        add a,4
        and 03Ch
        ld (xc_next),a
        or 2
        ld l,a
        ld a,(hl)               ; slot
        cp 0FFh
        jr z,.vok
        push hl
        ld l,a
        ld h,spr_stamp>>8
        ld a,(hl)
        pop hl
        neg
        add a,c
        cp 2
        jr nc,.vok
        djnz .v
.vok:   ld a,l
        and 03Ch
        ld l,a
        ld (hl),d
        inc l
        ld (hl),e
        inc l
        ld a,(hl)
        cp 0FFh
        jr z,.fill
        push hl                 ; the old slot stays in VRAM, but is free
        ld l,a
        ld h,0
        add hl,hl
        ld bc,spr_owner
        add hl,bc
        ld (hl),0FFh
        inc hl
        ld (hl),0FFh
        pop hl
.fill:  ld (xc_key),de
        push hl
        ld bc,10000h-spr_map
        add hl,bc
        ld (tmp_key),hl
        call spr_alloc
        pop hl
        ld (hl),e
        push de
        call spr_upload_x
        pop de
        ld a,BANK_CODE2
        call set_p2
        ld a,e
        pop de
        pop bc
        ret

; Upload code xc_key+1 with attribute xc_key (flip, colour group) to SGT
; slot E, recoloured with the group's sprite lookup PROM.
; Source: ROM bank SPRRAW_BANK + n/128, n = code + 256*flip, offset (n%128)*128.
spr_upload_x:
        push de
        ld a,(xc_key)
        and 00Fh
        ld hl,xr_grp
        cp (hl)
        call nz,xr_lut_build
        pop de
        ld a,(xc_key)
        ld b,1
        bit 6,a
        jr z,.fx
        dec b                   ; attribute bit 6 set: no flip X
.fx:    bit 7,a
        jr z,.fy
        set 1,b                 ; flip Y
.fy:    ld a,(xc_key+1)
        rla
        rl b
        rra                     ; B = (code + 256*flip) / 128
        ld c,a
        ld a,b
        add a,SPRRAW_BANK
        call set_p2
        ld a,c
        and 07Fh
        ld h,a
        ld l,0
        srl h
        rr l
        ld bc,08000h
        add hl,bc
        push hl
        ld a,e
        and 0F0h
        ld h,a
        ld l,0
        srl h
        rr l
        ld a,e
        and 00Fh
        add a,a
        add a,a
        add a,a
        or l
        ld l,a
        ld bc,VR_SGT&0FFFFh
        add hl,bc
        ex de,hl                ; DE = VRAM address
        pop hl                  ; HL = source
        ld b,16
.row:   push bc
        ex de,hl
        di
        ld a,VR_SGT>>16
        call v9_setw
        ex de,hl
        push de
        ld d,xr_lut>>8
        ld b,8
.px:    ld e,(hl)
        inc hl
        ld a,(de)
        out (V9_VRAM),a
        djnz .px
        pop de
        ld a,(game_busy)
        or a
        jr z,.noei
        ei
.noei:  ex de,hl
        ld bc,128
        add hl,bc
        ex de,hl
        pop bc
        djnz .row
        ret

; xr_lut := pixel pair -> recoloured pair for colour group A. Uses BC, DE, HL.
xr_lut_build:
        ld (xr_grp),a
        add a,a
        add a,a
        add a,a
        add a,a
        ld c,a
        ld b,0
        ld hl,slut_groups
        add hl,bc
        ld de,xr_lo
        ld b,16
.c:     ld a,(hl)
        ld (de),a               ; xr_lo[v] = colour
        rlca
        rlca
        rlca
        rlca
        set 4,e
        ld (de),a               ; xr_hi[v] = colour << 4
        res 4,e
        inc hl
        inc e
        djnz .c
        ld de,xr_lut
        ld h,xr_lo>>8
.p:     ld a,e
        rrca
        rrca
        rrca
        rrca
        and 00Fh
        or xr_hi&0FFh
        ld l,a
        ld c,(hl)
        ld a,e
        and 00Fh
        or xr_lo&0FFh
        ld l,a
        ld a,(hl)
        or c
        ld (de),a
        inc e
        jr nz,.p
        ret

; Upload sprite pattern tmp_key to SGT slot E.
; Source: ROM bank SPR_BANK + key/128, offset (key%128)*128, mapped at $8000.
spr_upload:
        ld hl,(tmp_key)
        ld a,l
        rla
        ld a,h
        rla                     ; A = key / 128
        add a,SPR_BANK
        call set_p2
        ld a,l
        and 07Fh
        ld h,a
        ld l,0
        srl h
        rr l                    ; HL = (key%128)*128
        ld bc,08000h
        add hl,bc
        push hl
        ; destination: SGT + (slot/16)*16*128 + (slot%16)*8
        ld a,e
        and 0F0h
        ld h,a
        ld l,0                  ; (slot/16)*16*256 / 2 -> rows of 128 bytes
        srl h
        rr l                    ; HL = (slot/16)*2048
        ld a,e
        and 00Fh
        add a,a
        add a,a
        add a,a
        or l
        ld l,a
        ld bc,VR_SGT&0FFFFh
        add hl,bc
        ex de,hl                ; DE = VRAM address
        pop hl                  ; HL = source
        ld b,16
.row:   push bc
        ex de,hl
        di
        ld a,VR_SGT>>16
        call v9_setw
        ex de,hl
        ld bc,8*256+V9_VRAM
        otir
        ld a,(game_busy)
        or a
        jr z,.noei
        ei                      ; only in the game tick (present runs with interrupts off)
.noei:
        ex de,hl
        ld bc,128
        add hl,bc
        ex de,hl
        pop bc
        djnz .row
        ret

; ---------------------------------------------------------------- tiles
; Dirty cells of the arcade tile RAM -> V9990 name tables.
; Cell (row r = idx>>5, column c = idx&31) of the hardware map:
;   c >= 4: plane B, row c (world column from the ring row and the camera)
;   c <= 3: plane A (HUD, arcade rows 0+1 merged, 2, 3), only for r = 2..29
present_tiles:
        ld a,40
        ld (cell_budget),a
.rows:  ld a,(dq_count)
        or a
        ret z                   ; nothing dirty: the usual case
        dec a
        or dq_list&255
        ld l,a
        ld h,dq_list>>8
        ld a,(hl)               ; row on top of the stack
        call tiles_row
        ret nz                  ; out of budget: the row stays on top
        ld hl,dq_count
        dec (hl)
        ld a,(cur_row)
        add a,dirty_rows&255
        ld l,a
        ld h,dirty_rows>>8
        ld (hl),0
        jr .rows

; A = hardware row: publish the dirty cells of the row (bits of its 4 mask
; bytes). Z = row done, NZ = out of budget (the remaining bits stay set).
tiles_row:
        ld (cur_row),a
        add a,a
        add a,a
        ld l,a
        ld h,dmask>>8           ; HL = mask of the row
        ld c,0                  ; column
.byte:  ld a,(hl)
        or a
        jr z,.clean
        ld b,a
        ld d,1                  ; bit of column C
.bit:   ld a,b
        and d
        jr z,.skip
        ld a,(cell_budget)
        or a
        jr z,.over
        ld a,b
        xor d
        ld b,a
        ld (hl),a               ; bit cleared before the cell is read
        push hl
        push bc
        push de
        call tile_cell
        pop de
        pop bc
        pop hl
.skip:  inc c
        rlc d
        jr nc,.bit
        jr .next
.clean: ld a,c
        add a,8
        ld c,a
.next:  inc l
        ld a,c
        cp 32
        jr nz,.byte
        xor a                   ; Z: done
        ret
.over:  inc a                   ; NZ
        ret

cur_row: db 0

; C = column, cur_row = row
tile_cell:
        ld a,c
        ld (cur_col),a
        ld a,(cur_row)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,l
        or c
        ld l,a                  ; HL = cell index
        push hl
        ld de,03C00h
        add hl,de
        ld e,(hl)               ; tile code
        ld a,h
        sub 4
        ld h,a
        ld d,(hl)               ; attribute
        pop hl
        ; skip HUD cells whose code and attribute were already sent
        ; (playfield cells are published whenever they are written)
        push hl
        ld a,c
        cp 4
        jr nc,.playfield
        ld bc,shadow_col
        add hl,bc
        ld a,(hl)
        cp d
        jr nz,.changed
        ld bc,shadow_vid-shadow_col
        add hl,bc
        ld a,(hl)
        cp e
        jr nz,.changed2
        pop hl
        ret
.changed:
        ld (hl),d
        ld bc,shadow_vid-shadow_col
        add hl,bc
.changed2:
        ld (hl),e
.playfield:
        pop hl
        ld a,(cur_col)
        ld c,a
        ld a,(cell_budget)
        dec a
        ld (cell_budget),a
        ld a,c
        cp 4
        jr nc,tile_b
        ; ---- plane A (HUD), columns 2..29 only. Arcade HUD rows 0-3 -> 3 rows:
        ; row 0 = arcade rows 0 and 1 merged (row 1 only holds "STEP n"),
        ; row 1 = arcade row 2, row 2 = arcade row 3
        ld a,(cur_row)
        cp 2
        ret c
        cp 30
        ret nc
        ld a,c
        cp 2
        jr nc,.hud23
        ; merged row: the arcade row 1 cell if it is not blank, else row 0
        ld a,(cur_row)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        inc hl                  ; cell (r, 1)
        ld bc,03C00h
        add hl,bc
        ld a,(hl)
        cp 010h
        jr nz,.r1
        dec hl                  ; cell (r, 0)
        ld a,(hl)
.r1:    ld e,a
        ld a,h
        sub 4
        ld h,a
        ld d,(hl)
        xor a
        jr .hud
.hud23: dec a                   ; arcade row 2 -> 1, 3 -> 2
.hud:   ld (cur_col),a          ; plane row
        ld a,d
        and 3
        ld d,a                  ; DE = pattern = code + 256 * (colour & 3)
        call pnt_offset
        ld bc,VR_PNTA&0FFFFh
        add hl,bc
        ld a,VR_PNTA>>16
        call v9_setw
        ld a,e
        out (V9_VRAM),a
        ld a,d
        out (V9_VRAM),a
        ret

tile_b: ; ---- plane B. The arcade keeps a ring of 32 map columns in its tile RAM:
        ; hardware row r holds world column w with w = 36 - r (mod 32), the
        ; ring window being [cam_x/8 - 2, cam_x/8 + 29]. The port keeps the whole
        ; map in plane B at column w + 8, so w is recovered from r and cam_x.
        ld a,(02AD1h)           ; cam_x low byte
        rrca
        rrca
        rrca
        and 01Fh
        sub 2
        ld b,a                  ; base = cam_x/8 - 2 (signed)
        ld a,(cur_row)
        ld c,a
        ld a,36
        sub c
        sub b
        and 01Fh
        add a,b
        add a,8
        ld (plane_col),a
        ld a,(cur_col)
        ld (plane_row),a
        bit 6,d
        jr nz,.hi
        bit 7,e
        jr nz,.hi
        ; code < 128: pattern = code + 128 * flip + 256 * colour
        ld a,e
        bit 5,d
        jr z,.nf
        or 080h
.nf:    ld e,a
        ld a,d
        and 00Fh
        ld d,a
        jr .put
.hi:    ; pattern = 4096 + (code9 - 128) + 384 * flip + 768 * (colour & 1)
        ld l,e
        ld h,0
        bit 6,d
        jr z,.lo
        inc h
.lo:    ld bc,4096-128
        add hl,bc
        bit 5,d
        jr z,.nf2
        ld bc,384
        add hl,bc
.nf2:   bit 0,d
        jr z,.nf3
        ld bc,768
        add hl,bc
.nf3:   ex de,hl
.put:   call pnt_offset_b
        ld bc,VR_PNTB&0FFFFh
        add hl,bc
        ld a,VR_PNTB>>16
        call v9_setw
        ld a,e
        out (V9_VRAM),a
        ld a,d
        out (V9_VRAM),a
        ret

; HL = (plane_row * 64 + plane_col) * 2. Keeps DE.
pnt_offset_b:
        ld a,(plane_row)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld a,(plane_col)
        or l
        ld l,a
        add hl,hl
        ret

plane_col: db 0
plane_row: db 0

; HL = (cur_col * 64 + 31 - cur_row) * 2. Keeps DE.
pnt_offset:
        ld a,(cur_col)
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl               ; col*64 (low 6 bits clear)
        ld a,(cur_row)
        ld b,a
        ld a,31
        sub b
        or l
        ld l,a
        add hl,hl
        ret

cur_col: db 0

; =============================================================================
; Inputs: MSX keyboard + joystick 1 -> arcade ports (active low)
;   cursor / joystick = move, SPACE / Z / trigger A = kick (button 1),
;   M / X / trigger B = jump (button 2); 1 / SPACE / trigger A = start in hard
;   mode, 2 / trigger B = start in medium mode (one player, no coins: always
;   free). SPACE and the triggers are starts only outside a game: in a game
;   (name entry) a start would end the entry.
; =============================================================================
read_input:
        xor a
        ld (start_now),a
        ld (start_btn),a
        ld c,0                  ; P1 bits, active high: 0 L 1 R 2 U 3 D 4 B1 5 B2
        ld a,8
        call kbd_row
        bit 4,a
        jr nz,$+4
        set 0,c
        bit 7,a
        jr nz,$+4
        set 1,c
        bit 5,a
        jr nz,$+4
        set 2,c
        bit 6,a
        jr nz,$+4
        set 3,c
        bit 0,a
        jr nz,.nsp
        set 4,c                 ; space
        ld hl,start_btn
        set 3,(hl)              ; also start 1
.nsp:
        ld a,5
        call kbd_row
        bit 7,a
        jr nz,$+4
        set 4,c                 ; Z
        bit 5,a
        jr nz,$+4
        set 5,c                 ; X
        ld a,4
        call kbd_row
        bit 2,a
        jr nz,$+4
        set 5,c                 ; M
        ; joystick port 1 (PSG register 14), active low: 0 U 1 D 2 L 3 R 4 A 5 B
        ld a,15
        out (0A0h),a
        in a,(0A2h)
        and 0BFh
        out (0A1h),a
        ld a,14
        out (0A0h),a
        in a,(0A2h)
        bit 0,a
        jr nz,$+4
        set 2,c
        bit 1,a
        jr nz,$+4
        set 3,c
        bit 2,a
        jr nz,$+4
        set 0,c
        bit 3,a
        jr nz,$+4
        set 1,c
        ld hl,start_btn
        bit 4,a
        jr nz,.nta
        set 4,c
        set 3,(hl)              ; trigger A: also start 1
.nta:   bit 5,a
        jr nz,.ntb
        set 5,c
        set 4,(hl)              ; trigger B: also start 2 (medium)
.ntb:
        ; behave like the arcade lever, which passes through the centre: a reversal
        ; without a neutral frame (easy on a keyboard) gets one, otherwise the game
        ; keeps the walk animation of the other side (it restarts it on a new press);
        ; both directions pressed: the last one pressed wins
        ld a,c
        and 3
        ld hl,joy_h
        call joy_axis
        ld b,a
        ld a,c
        rrca
        rrca
        and 3
        ld hl,joy_v
        call joy_axis
        rlca
        rlca
        or b
        ld b,a
        ld a,c
        and 0F0h
        or b
        cpl
        ld (io_p1),a
        ; system: 3 start 1 (hard), 4 start 2 (medium). A start is reported for 4 frames from
        ; the press, not while held: a kick still held when the attract mode
        ; comes back does not start a new game.
        ld a,(02A1Eh)           ; in_game
        or a
        jr nz,.ingame
        ld a,(start_btn)
        ld (start_now),a
.ingame:
        xor a
        call kbd_row
        ld hl,start_now
        bit 1,a
        jr nz,$+4
        set 3,(hl)              ; 1
        bit 2,a
        jr nz,$+4
        set 4,(hl)              ; 2
        ld a,(start_prev)
        cpl
        and (hl)                ; newly pressed
        ld c,a
        ld a,(hl)
        ld (start_prev),a
        ld a,c
        or a
        jr z,.hold
        ld (start_bits),a
        ld a,4
        ld (start_hold),a
.hold:  ld c,0
        ld a,(start_hold)
        or a
        jr z,.sys
        dec a
        ld (start_hold),a
        ld a,(start_bits)
        ld c,a
.sys:   ld a,c
        cpl
        ld (io_system),a
        ret

; one lever axis: A = raw bits (0-1), HL = [previous raw, winner of both, previous
; output]. Returns the bits to report. Keeps B, C.
joy_axis:
        ld e,a
        ld d,a
        cp 3
        jr nz,.have
        ld a,(hl)               ; previous raw
        cp 3
        jr z,.keep
        or a
        jr z,.win
        xor 3                   ; the key pressed last wins
.win:   inc hl
        ld (hl),a
        dec hl
.keep:  inc hl
        ld d,(hl)
        dec hl
.have:  ld (hl),e
        inc hl
        inc hl
        ld a,(hl)               ; previous output
        or a
        jr z,.out
        ld a,d
        or a
        jr z,.out
        cp (hl)
        jr z,.out
        ld d,0                  ; reversal: one neutral frame
.out:   ld (hl),d
        ld a,d
        ret

joy_h:  db 0,0,0
joy_v:  db 0,0,0

kbd_row:
        ld b,a
        in a,(0AAh)
        and 0F0h
        or b
        out (0AAh),a
        in a,(0A9h)
        ret

; Title screen texts (print_text records: screen address, ASCII - $30 tile codes,
; '@' blank, '/' new address, '?' end), through the text table entries 6, 8, 9
; (see DATA_PATCH in tools/xlat6809.py): the "Konami" logo and the copyright one
; game row higher than on the ranking screen, and the port's credit line under
; them, centred.
txt_title_logo:
        db 03Eh,079h,090h,091h
        db "@@@@"
        db 096h,"/",03Eh,07Ah
        db 0A0h,0A1h,0A2h,0A3h,0A4h,0A5h,0A6h,0A7h,"?"
txt_title_copyright:
        db 03Eh,0DCh
        db ":@KONAMI@1985?"
txt_title_credit:
        db 03Fh,03Dh
        db "MSX@V9990@DIHALT@2026?"

        include "sound.asm"
        include "../build/port/assets/sound.inc"
        include "../build/port/assets/palettes.asm"
