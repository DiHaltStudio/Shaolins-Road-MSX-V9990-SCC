; =============================================================================
; Shao-lin's Road for MSX1 + V9990: ROM header and boot (bank 0, $4000)
;
; 1. find the cartridge slot and map it on page 2 too (BIOS ENASLT)
; 2. find the RAM slot of page 3 and put that RAM on page 0 (the BIOS is gone
;    from here on; interrupts are handled at $0038 by the runtime)
; 3. copy bank 2 -> $0000 (runtime) and bank 3 -> $C000 (arcade data + code)
; 4. intro: the DiHalt logo (4 s), then the cover until a key or 10 s
; 5. V9990: P1 mode, palettes, all tile patterns, name tables, sprites off
; 6. arcade I/O defaults, V9990 vertical interrupt on, start the arcade program
; =============================================================================

ENASLT          equ 00024h
RSLREG          equ 00138h
EXPTBL          equ 0FCC1h
INITXT          equ 0006Ch      ; BIOS: SCREEN 0
ENASCR          equ 00044h      ; BIOS: screen on
CLS             equ 000C3h      ; BIOS: clear the screen (Z set)
POSIT           equ 000C6h      ; BIOS: cursor to column H, row L (1-based)
CHPUT           equ 000A2h      ; BIOS: print the character in A

        org 04000h
        db "AB"
        dw boot
        ds 12,0

boot:
        di
        ld sp,0F380h
        ; ---- V9990 found or not, in SCREEN 0 (the BIOS is still on page 0)
        call INITXT
        xor a
        call CLS
        call ENASCR
        ld hl,txt_credits
        call print_z
        call v9_detect
        jr z,.v9_found
        ld hl,00118h            ; H = column 1, L = row 24 (the last one)
        call POSIT
        ld hl,txt_not_found
        call print_z
        jr $                    ; no V9990: nothing else to do
.v9_found:
        ld hl,txt_found
        call print_z
        ld b,120                ; 2 s (MSX VDP frames)
.v9_wait:
        in a,(099h)
        rlca
        jr nc,.v9_wait
        djnz .v9_wait
        ; ---- cartridge slot (page 1) -> page 2
        call RSLREG
        rrca
        rrca
        and 3                   ; primary slot of page 1
        ld c,a
        ld b,0
        ld hl,EXPTBL
        add hl,bc
        ld a,(hl)
        and 080h
        or c
        ld c,a
        jp p,.cart_ok           ; not expanded
        inc hl
        inc hl
        inc hl
        inc hl
        ld a,(hl)               ; SLTTBL: secondary slot register of that slot
        and 00Ch                ; page 1 subslot, already in bits 3-2
        or c
        ld c,a
.cart_ok:
        ld a,c
        ld (boot_cart_slot),a
        ld h,080h
        call ENASLT
        di
        ld a,BANK_CODE2
        call boot_set_p2
        ; ---- find a RAM slot: test page 2 of every slot/subslot (ENASLT)
        ld b,0                  ; primary slot
.ram_prim:
        ld c,b
        ld hl,EXPTBL
        ld a,l
        add a,b
        ld l,a
        ld a,(hl)
        and 080h
        jr z,.ram_try1
        ; expanded: try the four subslots
        ld e,0
.ram_sub:
        ld a,e
        rlca
        rlca
        or 080h
        or b
        call ram_test_slot
        jr z,.ram_found
        inc e
        ld a,e
        cp 4
        jr nz,.ram_sub
        jr .ram_next
.ram_try1:
        ld a,b
        call ram_test_slot
        jr z,.ram_found
.ram_next:
        inc b
        ld a,b
        cp 4
        jr nz,.ram_prim
        di
        jr $                    ; no RAM found
.ram_found:
        ld (boot_ram_slot),a
        ; ---- SCC: this cartridge first (Konami SCC mapper), then every other
        ; slot/subslot. boot_scc_slot = slot id, $FF = none.
        ld a,(boot_cart_slot)
        IF SCC_SKIP_OWN
        ld a,0FFh               ; test build: ignore the SCC of this cartridge
        ELSE
        call scc_test_slot
        jr z,.scc_found
        ENDIF
        ld b,0
.scc_prim:
        ld hl,EXPTBL
        ld a,l
        add a,b
        ld l,a
        ld a,(hl)
        and 080h
        jr z,.scc_one
        ld e,0
.scc_sub:
        ld a,e
        rlca
        rlca
        or 080h
        or b
        call scc_test_other
        jr z,.scc_found
        inc e
        ld a,e
        cp 4
        jr nz,.scc_sub
        jr .scc_next
.scc_one:
        ld a,b
        call scc_test_other
        jr z,.scc_found
.scc_next:
        inc b
        ld a,b
        cp 4
        jr nz,.scc_prim
        ld a,0FFh               ; no SCC: effects only on the PSG
.scc_found:
        ld (boot_scc_slot),a
        ld a,(boot_cart_slot)
        ld h,080h
        call ENASLT             ; cartridge back on page 2
        di
        ld a,BANK_CODE2
        call boot_set_p2
        ; ---- page 0 := RAM slot. If it is expanded, its subslot register must be
        ; written with page 3 in that primary slot (no stack use meanwhile).
        ld a,(boot_ram_slot)
        and 3
        ld c,a                  ; primary
        ld a,(boot_ram_slot)
        rrca
        rrca
        and 3
        ld e,a                  ; subslot
        ld a,(boot_ram_slot)
        bit 7,a
        jr z,.prim
        in a,(0A8h)
        ld d,a                  ; current primary slots
        and 03Fh
        ld b,a
        ld a,c
        rrca
        rrca
        or b
        out (0A8h),a            ; page 3 -> RAM primary slot
        ld a,(0FFFFh)
        cpl
        and 0FCh
        or e
        ld (0FFFFh),a           ; page 0 subslot of that slot
        ld a,d
        out (0A8h),a            ; page 3 back
.prim:  in a,(0A8h)
        and 0FCh
        or c
        out (0A8h),a
        ; ---- runtime: bank 2 -> $0000-$3FFF (only $0000-$27FF is used)
        ld a,2
        call boot_set_p2
        ld hl,08000h
        ld de,00000h
        ld bc,02800h
        ldir
        ld sp,02000h
        ld a,(boot_scc_slot)
        push af                 ; page 3 is overwritten below
        ld a,(boot_cart_slot)
        push af
        ; ---- arcade data + code: bank 3 -> $C000-$FFEF ($FFFF is the subslot register)
        ld a,3
        call boot_set_p2
        ld hl,08000h
        ld de,0C000h
        ld bc,03FF0h
        ldir
        ld a,BANK_CODE2
        call boot_set_p2
        ; ---- clear the arcade RAM $2800-$3FFF and the runtime variables
        ld hl,02000h
        ld de,02001h
        ld bc,02000h-1
        ld (hl),0
        ldir
        pop af
        ld (cart_slot),a
        pop af
        ld (scc_slot),a
        ld hl,spr_map
        ld de,spr_map+1
        ld bc,3072-1
        ld (hl),0FFh
        ldir
        ld hl,shadow_col
        ld de,shadow_col+1
        ld bc,1023
        ld (hl),0FFh
        ldir
        ; attr_tab: sprite attribute -> spr_map page (flip + 4 * colour),
        ; 0 for colour groups 3..15 (xcache)
        ld hl,attr_tab
.at:    ld a,l
        and 00Fh
        cp 3
        jr c,.atc
        ld (hl),0
        jr .atn
.atc:   add a,a
        add a,a
        bit 6,l
        jr nz,.atx
        inc a                   ; flip X (attribute bit 6 clear)
.atx:   bit 7,l
        jr z,.aty
        add a,2                 ; flip Y
.aty:   add a,spr_map>>8
        ld (hl),a
.atn:   inc l
        jr nz,.at
        ld hl,xcache
        ld de,xcache+1
        ld bc,64-1
        ld (hl),0FFh
        ldir
        ld a,0FFh
        ld (xr_grp),a
        xor a
        ld (xc_next),a
        ld hl,spr_owner
        ld de,spr_owner+1
        ld bc,511
        ld (hl),0FFh
        ldir
        ; ---- TMS9918: no interrupts, display off, black backdrop (what is seen
        ; while the V9990 display is off, e.g. in openMSX)
        ld a,080h
        out (099h),a
        ld a,081h
        out (099h),a
        ld a,001h
        out (099h),a
        ld a,087h
        out (099h),a            ; R#7: backdrop colour 1 (black)
        in a,(099h)
        ; ---- intro pictures, then the V9990 for the game
        call intro
        call v9_init
        call sndp_init
        ; ---- arcade I/O defaults (raw, active low)
        ld a,0FFh
        ld (io_system),a
        ld (io_p1),a
        ld (io_p2),a
        xor a
        ld (io_vpos),a
        ld (io_scroll),a
        ld a,5
        ld (io_palbank),a
        ld a,0FFh
        ld (pal_cur),a
        ld a,14
        ld (camoff),a
        xor a
        ld (game_busy),a
        ld (tick_debt),a
        ld hl,spat_a
        ld (spat_show),hl
        ld hl,spat_b
        ld (spat_build),hl
        ld hl,spat_a            ; both buffers: all sprites disabled
        call .spinit
        ld hl,spat_b
        call .spinit
        jr .spdone
.spinit:
        ld b,24
.spi:   ld (hl),216
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        inc hl
        ld (hl),010h
        inc hl
        djnz .spi
        ret
.spdone:
        ld a,0FFh
        ld (scby_cur),a
        ld a,1
        ld (xl_game_on),a
        ; ---- V9990 vertical interrupt on, then the arcade program (init_game)
        ld a,7
        out (V9_INT),a          ; clear pending flags
        ld a,9
        ld c,1
        call v9_reg             ; R#9: IEV
        im 1
        jp init_game

boot_cart_slot: equ 0F300h        ; page 3 RAM, used before the page 3 image is copied
boot_ram_slot:  equ 0F301h
boot_scc_slot:  equ 0F302h

; A = slot ID: map it on page 2 and test RAM at $BFFF. Z = RAM. Keeps B, E.
ram_test_slot:
        push bc
        push de
        push af
        ld h,080h
        call ENASLT
        di
        ld hl,0BFFFh
        ld a,(hl)
        cpl
        ld (hl),a
        cp (hl)
        cpl
        ld (hl),a
        pop bc                  ; B = slot ID
        ld a,b
        pop de
        pop bc
        ret

; ---------------------------------------------------------------- V9990 setup
v9_init:
        ld a,2
        out (V9_SYS),a          ; soft reset
        xor a
        out (V9_SYS),a
        ld a,6
        ld c,005h
        call v9_reg             ; R#6: P1, image 512 wide, 4 bpp
        ld a,7
        ld c,000h
        call v9_reg             ; R#7: NTSC, non-interlaced
        ld a,8
        ld c,002h
        call v9_reg             ; R#8: display off
        ld a,9
        ld c,000h
        call v9_reg             ; R#9: no interrupts yet
        ld a,7
        out (V9_INT),a
        ld a,13
        ld c,001h
        call v9_reg             ; R#13: plane A block 1, plane B block 0
        ld a,15
        ld c,000h
        call v9_reg             ; backdrop colour 0
        ld a,16
        ld c,000h
        call v9_reg
        ld b,8                  ; scroll registers R#17-24 = 0
        ld a,17
.scr:   push bc
        push af
        ld c,0
        call v9_reg
        pop af
        inc a
        pop bc
        djnz .scr
        ld a,25
        ld c,(VR_SGT>>15)<<1
        call v9_reg             ; sprite generator at VR_SGT
        ld a,27
        ld c,000h
        call v9_reg
        ; palettes: banks 5 (title) for blocks 0/1, block 2 = sprites, block 3 = black
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a
        ld hl,pal_banks+5*96
        ld bc,96*256+V9_PAL
        otir
        ld hl,pal_sprites
        ld bc,48*256+V9_PAL
        otir
        ld b,48
        xor a
.pb3:   out (V9_PAL),a
        djnz .pb3
        ld a,5
        ld (pal_cur),a
        ; patterns: plane B (11 banks) at $40000, plane A (2 banks) at $00000
        ld a,VR_PATB>>16
        ld hl,VR_PATB&0FFFFh
        call v9_setw
        ld a,PATB_BANK
        ld e,11
        call upload_banks
        ld a,VR_PATA>>16
        ld hl,VR_PATA&0FFFFh
        call v9_setw
        ld a,PATA_BANK
        ld e,2
        call upload_banks
        ; plane A pattern 1023: transparent
        ; (pattern n: x = 8*(n%32), y = 8*(n/32): n = 1023 -> x 248, y 248)
        ld d,8
        ld hl,248*128+124
.clr:   ld a,VR_PATA>>16
        call v9_setw
        xor a
        out (V9_VRAM),a
        out (V9_VRAM),a
        out (V9_VRAM),a
        out (V9_VRAM),a
        ld bc,128
        add hl,bc
        dec d
        jr nz,.clr
        ; name table A: rows 0-2 HUD blank (opaque black), margins opaque, rest transparent
        ld a,VR_PNTA>>16
        ld hl,VR_PNTA&0FFFFh
        call v9_setw
        ld d,64                 ; rows
.ra:    ld e,64                 ; columns
.ca:    ld a,64
        sub d                   ; row
        cp 3
        jr c,.opaque
        ld a,64
        sub e                   ; column
        cp 2
        jr c,.opaque
        cp 30
        jr nc,.opaque
        ld a,PAT_A_CLEAR&255
        out (V9_VRAM),a
        ld a,PAT_A_CLEAR>>8
        out (V9_VRAM),a
        jr .na
.opaque:
        ld a,PAT_A_BLANK
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
.na:    dec e
        jr nz,.ca
        dec d
        jr nz,.ra
        ; name table B: blank
        ld a,VR_PNTB>>16
        ld hl,VR_PNTB&0FFFFh
        call v9_setw
        ld de,4096
.rb:    ld a,PAT_B_BLANK
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
        dec de
        ld a,d
        or e
        jr nz,.rb
        ; sprites: all 125 disabled
        ld a,VR_SPAT>>16
        ld hl,VR_SPAT&0FFFFh
        call v9_setw
        ld b,128
.sp:    ld a,216
        out (V9_VRAM),a
        xor a
        out (V9_VRAM),a
        out (V9_VRAM),a
        ld a,010h
        out (V9_VRAM),a
        djnz .sp
        ; display on
        ld a,8
        ld c,082h
        call v9_reg
        ret

; scc_test_other: as scc_test_slot for slot A unless it is this cartridge (NZ).
scc_test_other:
        ld hl,boot_cart_slot
        cp (hl)
        jr nz,scc_test_slot
        or a
        ret nz
        inc a                   ; slot 0 = cartridge: NZ
        ret

; scc_test_slot: put slot A (ENASLT id) on page 2 and look for an SCC: $9800 must not
; be writable before $3F is written to $9000 (RAM, other devices), and must be after.
; Z = SCC found (left silent, A = slot id). Keeps B, E.
scc_test_slot:
        push bc
        push de
        ld c,a
        push bc
        ld h,080h
        call ENASLT
        di
        pop bc
        ld hl,09800h
        ld a,(hl)
        cpl
        ld (hl),a
        cp (hl)
        jr nz,.closed
        cpl
        ld (hl),a               ; already writable: not an SCC
        jr .no
.closed:
        ld a,03Fh
        ld (09000h),a           ; SCC registers at $9800-$98FF
        ld a,055h
        ld (hl),a
        cp (hl)
        jr nz,.off
        cpl
        ld (hl),a
        cp (hl)
        jr nz,.off
        xor a
        ld (0988Fh),a           ; all SCC channels off
        ; channels 1-4 (5 shares 4): square wave, as the SN76489
        ld hl,09800h
        ld b,4
.wave:  ld d,16
.hi:    ld (hl),07Fh
        inc hl
        dec d
        jr nz,.hi
        ld d,16
.lo:    ld (hl),080h
        inc hl
        dec d
        jr nz,.lo
        djnz .wave
        ld a,c
        pop de
        pop bc
        cp a                    ; Z
        ret
.off:   ld a,BANK_CODE2*2
        ld (09000h),a           ; not an SCC: ROM bank back (harmless elsewhere)
.no:    ld a,c
        pop de
        pop bc
        or a
        ret nz
        inc a                   ; NZ even for slot id 0
        ret

; Map 16 KiB bank A at $8000-$BFFF (Konami SCC mapper, 8 KiB banks 2A, 2A+1). Keeps A.
boot_set_p2:
        push af
        add a,a
        ld (KSCC_B2),a
        inc a
        ld (KSCC_B3),a
        pop af
        ret

; =============================================================================
; Intro: the DiHalt logo in B1 (256x212, BD8: the 256 fixed RGB332 colours) for
; 4 s, not skippable; then the cover in B3 (512x424 interlaced, BD8) until a key
; or a joystick direction/button (either port) is pressed, at most 10 s. The
; pictures are RLE streams (tools/intro_assets.py) in banks INTRO_BANK+.
; The logo is decoded at VRAM $40000 and shown there (SCAY = 1024 lines of 256
; bytes); the cover is decoded at VRAM 0 while the logo is on screen. Frames are
; counted with the V9990 vertical blank flag (interrupts stay off).
; The V9990 is left with the display off; v9_init sets it up for the game.
; =============================================================================
intro:
        ld a,2
        out (V9_SYS),a          ; soft reset
        xor a
        out (V9_SYS),a
        ld hl,intro_b1
        call intro_regs
        xor a
        call intro_border       ; black while the logo is decoded
        ld a,INTRO_LOGO_BANK
        ld hl,INTRO_LOGO_ADDR
        ld b,4                  ; VRAM $40000
        call intro_unrle
        ld a,0FFh
        call intro_border       ; white, as the logo's background
        ld a,8
        ld c,082h
        call v9_reg             ; R#8: display on
        ld a,7
        out (V9_INT),a          ; clear the flags: frames counted from here
        xor a
        ld (intro_frames),a
        ld a,INTRO_OPEN_BANK
        ld hl,INTRO_OPEN_ADDR
        ld b,0                  ; VRAM 0
        call intro_unrle
.logo:  call intro_tick
        ld a,(intro_frames)
        cp 240                  ; 4 s
        jr c,.logo
        ; cover: B3 from the next vertical blank
        call intro_frame
        ld hl,intro_b3
        call intro_regs
        xor a
        call intro_border
        ld bc,600               ; 10 s
.open:  call intro_frame
        call intro_input
        jr nz,.key
        dec bc
        ld a,b
        or c
        jr nz,.open
        jr .off
.key:   ld b,30                 ; let the key go (at most 0.5 s): it must not
.rel:   call intro_frame        ; reach the game as a coin or a start
        call intro_input
        jr z,.off
        djnz .rel
.off:   ld a,8
        ld c,002h
        call v9_reg             ; R#8: display off
        ld a,BANK_CODE2
        jp boot_set_p2

; register lists [register, value], 0FFh ends
intro_b1:
        db 6,082h               ; bitmap, 256 pixels, image 256 wide, 8 bpp
        db 7,000h               ; non-interlaced
        db 9,000h               ; no interrupts
        db 13,040h              ; BD8: 256 fixed RGB332 colours
        db 15,000h              ; border = palette entry 0
        db 17,000h,18,004h      ; SCAY = 1024: the logo at $40000
        db 19,000h,20,000h      ; SCAX = 0
        db 8,002h               ; display off
        db 0FFh
intro_b3:
        db 6,096h               ; bitmap, 512 pixels, image 512 wide, 8 bpp
        db 7,006h               ; EO, IL: 424 lines interlaced
        db 17,000h,18,000h      ; SCAY = 0
        db 8,082h               ; display on
        db 0FFh

intro_regs:
        ld a,(hl)
        cp 0FFh
        ret z
        inc hl
        ld c,(hl)
        inc hl
        call v9_reg
        jr intro_regs

; border (palette entry 0) := A (0 black, $FF white)
intro_border:
        ld c,a
        ld a,14
        out (V9_REGS),a
        xor a
        out (V9_REGD),a         ; R#14: palette entry 0
        ld a,c
        and 01Fh
        out (V9_PAL),a          ; R, G, B (5 bits each)
        out (V9_PAL),a
        out (V9_PAL),a
        ret

; Decode the RLE stream at HL of intro bank A to VRAM B:0000. Literal blocks are
; sent with otir unless they may cross the end of the bank; the vertical blanks
; are counted (intro_tick) between blocks.
intro_unrle:
        add a,INTRO_BANK
        ld (intro_bank),a
        call boot_set_p2
        push hl
        ld a,b
        ld hl,0
        call v9_setw
        pop hl
        ld c,V9_VRAM
.next:  call intro_tick
        ld a,(hl)
        inc hl
        bit 6,h
        call nz,.bank
        cp 0FFh
        ret z
        bit 7,a
        jr nz,.run
        inc a
        ld b,a                  ; c + 1 literal bytes
        ld a,h
        cp 0BFh
        jr nc,.slow             ; near the end of the bank: byte by byte
        otir
        jr .next
.slow:  ld a,(hl)
        inc hl
        bit 6,h
        call nz,.bank
        out (c),a
        djnz .slow
        jr .next
.run:   and 07Fh
        add a,2
        ld b,a                  ; (c & $7F) + 2 times the next byte
        ld a,(hl)
        inc hl
        bit 6,h
        call nz,.bank
.rep:   out (c),a
        djnz .rep
        jr .next
.bank:  push af                 ; HL = $C000: next bank at $8000
        ld a,(intro_bank)
        inc a
        ld (intro_bank),a
        call boot_set_p2
        ld h,080h
        pop af
        ret

; Count a vertical blank if one happened (V9990 VI flag). Keeps BC, DE, HL.
intro_tick:
        in a,(V9_INT)
        rrca
        ret nc
        ld a,1
        out (V9_INT),a
        ld a,(intro_frames)
        inc a
        ret z                   ; saturates at 255
        ld (intro_frames),a
        ret

; Wait for the next vertical blank. Keeps BC, DE, HL.
intro_frame:
        ld a,1
        out (V9_INT),a
.w:     in a,(V9_INT)
        rrca
        jr nc,.w
        ret

; NZ if a key (keyboard rows 0-10) or a direction/button of a joystick is
; pressed. Keeps BC.
intro_input:
        push bc
        ld b,11
        ld c,0
.row:   in a,(0AAh)
        and 0F0h
        or c
        out (0AAh),a
        in a,(0A9h)
        inc a
        jr nz,.yes              ; a bit at 0: pressed
        inc c
        djnz .row
        ld c,0                  ; joystick port 1, then 2
.joy:   ld a,15
        out (0A0h),a
        in a,(0A2h)
        and 0BFh
        or c
        out (0A1h),a            ; R#15: port select
        ld a,14
        out (0A0h),a
        in a,(0A2h)
        or 0C0h
        inc a
        jr nz,.yes
        ld a,c
        xor 040h
        ld c,a
        jr nz,.joy
        xor a                   ; Z: nothing
        pop bc
        ret
.yes:   or 1                    ; NZ
        pop bc
        ret

intro_bank:     equ 02400h      ; RT_VARS scratch before the game (set again later)
intro_frames:   equ 02401h

; Z = a V9990 answers: register 15 (border colour, 6 bits) keeps what is written.
; Without one the port reads $FF.
v9_detect:
        ld a,15
        out (064h),a
        ld a,02Ah
        out (063h),a
        ld a,15
        out (064h),a
        in a,(063h)
        and 03Fh
        cp 02Ah
        ret nz
        ld a,15
        out (064h),a
        ld a,015h
        out (063h),a
        ld a,15
        out (064h),a
        in a,(063h)
        and 03Fh
        cp 015h
        ret nz
        ld a,15
        out (064h),a
        xor a
        out (063h),a            ; border colour 0; Z
        ret

; print the zero-terminated string at HL with the BIOS
print_z:
        ld a,(hl)
        or a
        ret z
        inc hl
        push hl
        call CHPUT
        pop hl
        jr print_z

txt_credits:    db "KONAMI 1985",13,10,"DIHALT STUDIO 2026",13,10,13,10,0
txt_found:      db "V9990 found !",0
txt_not_found:  db "V9990 NOT found!!!",0

; Upload E banks starting at bank A (16 KiB each, mapped at $8000) to the
; current VRAM write address.
upload_banks:
.bank:  call boot_set_p2
        push af
        ld hl,08000h
        ld c,V9_VRAM
        ld d,64
.blk:   ld b,0
        otir
        dec d
        jr nz,.blk
        pop af
        inc a
        dec e
        jr nz,.bank
        ld a,BANK_CODE2
        call boot_set_p2
        ret

        include "../build/port/assets/intro.inc"
