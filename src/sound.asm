; =============================================================================
; Sound player: the arcade sounds, captured from the real driver and packed by
; tools/sound_pack.py as event streams (see there for the format), one stream for
; the music (voices M0-M3) and one for the effects (E0, E1, noise).
;
; Output, chosen at boot (scc_slot):
;   SCC + PSG  music M0-M3 on SCC channels 1-4 (square waves), effects on the PSG:
;              E0 -> A, E1 -> B, noise -> C
;   PSG only   melody M2 -> A, bass M0 -> B, effects on C (tone E0 and/or noise)
;
; Commands come from the arcade code itself: sndp_irq_tick (translated) hands one
; byte per frame to sndp_cmd/sndp_cmd_new ($2830/$2831), as for the original NMI
; driver, with the same rules: effects $0C and $15 cannot be interrupted by another
; effect, music 9 (game start, which goes on with the stage 1 theme) not by music.
; A tempo command ($20-$3F) after a stage theme switches to its fast version; on
; music 9 the fast stage 1 theme takes over at the same place (seek table).
; =============================================================================

SND_CMD         equ 02830h
SND_CMD_NEW     equ 02831h

; stream records (page 3 RAM, reserved area): 32 bytes each, addressed with IX
SR_ON           equ 0               ; 0 = stopped
SR_ID           equ 1               ; command (low nibble for music)
SR_FAST         equ 2               ; music: fast version playing
SR_BANK         equ 3
SR_PTR          equ 4               ; 2
SR_WAIT         equ 6               ; frames still to wait
SR_LBANK        equ 7               ; loop point
SR_LPTR         equ 8               ; 2
SR_T            equ 10              ; 2: frame counter (music 9 -> seek)
SR_LT           equ 12              ; 2: frame counter at the loop point
SR_Q            equ 16              ; 4 x 2: voice periods (PSG period, SCC register + 1)
SR_ATT          equ 24              ; 4: voice attenuations (15 = off)
SR_NP           equ 28              ; noise period
SR_DIRTY        equ 29              ; a voice changed this frame: write the chip

sndp_mus         equ 0F380h
sndp_sfx         equ 0F3A0h
p2_cur          equ 0F37Fh          ; 16 KiB bank mapped at $8000 (set_p2), restored after reading

; ---------------------------------------------------------------- frame
sndp_frame:
        xor a
        ld (sndp_dirty),a
        call sndp_intake
        ld ix,sndp_mus
        call sndp_parse
        ld ix,sndp_sfx
        call sndp_parse
        ; most frames only count a wait: nothing to write, no bank was mapped
        ld a,(sndp_dirty)
        or a
        ret z
        call sndp_restore_p2
        ld a,(scc_slot)
        inc a
        jp z,sndp_out_psg_only
        ld a,(sndp_mus+SR_DIRTY)
        or a
        call nz,sndp_out_scc
        ld a,(sndp_sfx+SR_DIRTY)
        or a
        ret z
        jp sndp_out_psg_sfx

; map 16 KiB data bank A at $8000 (the shadow p2_cur keeps the bank of the program)
sndp_map:
        add a,SND_BANK
        add a,a
        ld (KSCC_B2),a
        inc a
        ld (KSCC_B3),a
        ret

sndp_dirty:      db 0                ; a voice changed, or a sound bank was mapped, this frame

sndp_restore_p2:
        ld a,(p2_cur)
        add a,a
        ld (KSCC_B2),a
        inc a
        ld (KSCC_B3),a
        ret

; ---------------------------------------------------------------- commands
sndp_intake:
        ld a,(SND_CMD_NEW)
        or a
        ret z
        xor a
        ld (SND_CMD_NEW),a
        ld a,(SND_CMD)
        or a
        jr z,sndp_stop_all
        bit 7,a
        ret nz
        bit 6,a
        jr nz,.music
        bit 5,a
        jr nz,.tempo
        cp 018h
        ret nc
        ; effect: $0C and $15 are not interrupted
        ld c,a
        ld a,(sndp_sfx+SR_ON)
        or a
        jr z,.sfx
        ld a,(sndp_sfx+SR_ID)
        cp 00Ch
        ret z
        cp 015h
        ret z
.sfx:   ld a,c
        ld ix,sndp_sfx
        jp sndp_start
.music: cp 050h
        ret nc
        and 00Fh
        ld c,a
        ld a,(sndp_mus+SR_ON)
        or a
        jr z,.mus
        ld a,(sndp_mus+SR_ID)
        cp 9
        ret z                   ; game start music: not interrupted
.mus:   ld ix,sndp_mus
        ld (ix+SR_FAST),0
        ld a,c
        add a,24
        call sndp_start
        ld (ix+SR_ID),c
        ret
.tempo: ld ix,sndp_mus
        ld a,(ix+SR_ON)
        or a
        ret z
        ld a,(ix+SR_FAST)
        or a
        ret nz
        ld a,(ix+SR_ID)
        cp 9
        jp z,sndp_seek_fast
        ld c,a
        add a,40
        call sndp_start
        ret c                   ; no fast version: keep the theme
        ld (ix+SR_ID),c
        ld (ix+SR_FAST),1
        ret

sndp_stop_all:
        xor a
        ld (sndp_mus+SR_ON),a
        dec a
        ld (sndp_dirty),a
        ld (sndp_mus+SR_DIRTY),a
        ld (sndp_sfx+SR_DIRTY),a
        xor a
        ld (sndp_sfx+SR_ON),a
        ld a,15
        ld hl,sndp_mus+SR_ATT
        ld b,4
.m:     ld (hl),a
        inc hl
        djnz .m
        ld hl,sndp_sfx+SR_ATT
        ld b,4
.s:     ld (hl),a
        inc hl
        djnz .s
        ret

; start stream A of the index (effect n, 24 + music n, 40 + fast music n) in record IX.
; CY = no such stream (nothing changed). Keeps C.
sndp_start:
        ld (sndp_dirty),a       ; A <> 0: the index bank is mapped below
        ld (ix+SR_DIRTY),a
        ld e,a
        ld d,0
        ld l,a
        ld h,d
        add hl,hl
        add hl,de               ; 3 * A
        ld de,08000h
        add hl,de
        xor a
        call sndp_map            ; the index is at the start of the first sound bank
        ld a,(hl)
        cp 0FFh
        scf
        ret z
        ld (ix+SR_BANK),a
        inc hl
        ld a,(hl)
        ld (ix+SR_PTR),a
        inc hl
        ld a,(hl)
        ld (ix+SR_PTR+1),a
        xor a
        ld (ix+SR_WAIT),a
        ld (ix+SR_T),a
        ld (ix+SR_T+1),a
        ld (ix+SR_ID),c
        inc a
        ld (ix+SR_ON),a
        or a                    ; NC
        ret

; music 9 + tempo: go on with the fast stage 1 theme at the same place.
; theme frame u = t - SND_JINGLE, fast frame v = u * SND_RATIO / 256; the seek entry
; v / SND_KEY gives the stream position and the voices, then v % SND_KEY frames are
; played silently.
sndp_seek_fast:
        ld l,(ix+SR_T)
        ld h,(ix+SR_T+1)
        ld de,-SND_JINGLE
        add hl,de
        jr c,.u
        ld hl,0                 ; still in the jingle: start of the theme
.u:     ld b,h
        ld c,l                  ; BC = u
        ld hl,0
        ld d,0                  ; D:HL = u * SND_RATIO
        ld a,SND_RATIO
        ld e,8
.m:     add hl,hl
        rl d
        rla
        jr nc,.mn
        add hl,bc
        jr nc,.mn
        inc d
.mn:    dec e
        jr nz,.m
        ld l,h
        ld h,d                  ; HL = v
        ld a,l
        and SND_KEY-1
        ld (sndp_ff),a
        ld a,l
        and 0E0h
        ld l,a
        ld (sndp_vt),hl          ; frame of the entry
        add hl,hl
        add hl,hl
        add hl,hl
        ld c,h                  ; C = entry = v / 32
        xor a
        call sndp_map            ; the seek table is in the first sound bank
        ld (sndp_dirty),a       ; the voices are reloaded from the table
        ld (ix+SR_DIRTY),a
        ld hl,SND_SEEK
        ld a,c
        cp (hl)
        jr c,.in
        ld a,(hl)
        dec a                   ; past the table: last entry, no fast-forward
        ld c,a
        ld l,a
        ld h,0
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        ld (sndp_vt),hl
        xor a
        ld (sndp_ff),a
        ld hl,SND_SEEK
.in:    inc hl
        ld a,(hl)
        ld (ix+SR_LBANK),a
        inc hl
        ld a,(hl)
        ld (ix+SR_LPTR),a
        inc hl
        ld a,(hl)
        ld (ix+SR_LPTR+1),a
        inc hl
        ld a,(hl)
        ld (ix+SR_LT),a
        inc hl
        ld a,(hl)
        ld (ix+SR_LT+1),a
        inc hl
        ; entry C: 15 bytes
        push hl
        ld l,c
        ld h,0
        ld e,l
        ld d,h
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,hl
        or a
        sbc hl,de
        pop de
        add hl,de
        ld a,(hl)
        ld (ix+SR_BANK),a
        inc hl
        ld a,(hl)
        ld (ix+SR_PTR),a
        inc hl
        ld a,(hl)
        ld (ix+SR_PTR+1),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+1),a
        inc hl
        ld a,(hl)
        ld (ix+SR_ATT),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+2),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+3),a
        inc hl
        ld a,(hl)
        ld (ix+SR_ATT+1),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+4),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+5),a
        inc hl
        ld a,(hl)
        ld (ix+SR_ATT+2),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+6),a
        inc hl
        ld a,(hl)
        ld (ix+SR_Q+7),a
        inc hl
        ld a,(hl)
        ld (ix+SR_ATT+3),a
        ld hl,(sndp_vt)
        ld (ix+SR_T),l
        ld (ix+SR_T+1),h
        xor a
        ld (ix+SR_WAIT),a
        ld (ix+SR_FAST),1
        ld a,(sndp_ff)
        or a
        ret z
        ld b,a
.ff:    push bc
        call sndp_parse
        pop bc
        djnz .ff
        ret

sndp_ff:         db 0
sndp_vt:         dw 0

; ---------------------------------------------------------------- streams
; one frame of the stream in record IX
sndp_parse:
        ld a,(ix+SR_ON)
        or a
        ret z
        ld a,(ix+SR_WAIT)
        or a
        jr z,.read
        dec (ix+SR_WAIT)
        jr .time
.read:  ld a,(ix+SR_BANK)
        call sndp_map
        ld (sndp_dirty),a       ; A <> 0 (bank 2 * (SND_BANK + n))
        ld (ix+SR_DIRTY),a
        ld l,(ix+SR_PTR)
        ld h,(ix+SR_PTR+1)
.ev:    ld a,(hl)
        inc hl
        bit 7,a
        jr nz,.wait
        cp 3
        jr c,.ctl
        cp 020h
        jr c,.per
        cp 040h
        jr c,.noise
        ; $40 + 16 v + attenuation
        ld c,a
        rrca
        rrca
        rrca
        rrca
        and 3
        add a,SR_ATT
        ld (.sa+2),a            ; displacement of the store (the runtime is in RAM)
        ld a,c
        and 00Fh
.sa:    ld (ix+SR_ATT),a
        jr .ev
.per:   ; $10 + v, lo, hi
        and 3
        add a,a
        add a,SR_Q
        ld (.sq+2),a
        inc a
        ld (.sq2+2),a
        ld a,(hl)
        inc hl
.sq:    ld (ix+SR_Q),a
        ld a,(hl)
        inc hl
.sq2:   ld (ix+SR_Q+1),a
        jr .ev
.noise: and 01Fh
        ld (ix+SR_NP),a
        jr .ev
.wait:  and 07Fh
        dec a
        ld (ix+SR_WAIT),a
        ld (ix+SR_PTR),l
        ld (ix+SR_PTR+1),h
.time:  inc (ix+SR_T)
        ret nz
        inc (ix+SR_T+1)
        ret
.ctl:   or a
        jr z,.end
        dec a
        jr nz,.jump
        ; $01: loop point
        ld a,(ix+SR_BANK)
        ld (ix+SR_LBANK),a
        ld (ix+SR_LPTR),l
        ld (ix+SR_LPTR+1),h
        ld a,(ix+SR_T)
        ld (ix+SR_LT),a
        ld a,(ix+SR_T+1)
        ld (ix+SR_LT+1),a
        jp .ev
.jump:  ; $02: back to the loop point
        ld a,(ix+SR_LBANK)
        ld (ix+SR_BANK),a
        call sndp_map
        ld l,(ix+SR_LPTR)
        ld h,(ix+SR_LPTR+1)
        ld a,(ix+SR_LT)
        ld (ix+SR_T),a
        ld a,(ix+SR_LT+1)
        ld (ix+SR_T+1),a
        jp .ev
.end:   ld (ix+SR_ON),0
        ld a,15
        ld (ix+SR_ATT),a
        ld (ix+SR_ATT+1),a
        ld (ix+SR_ATT+2),a
        ld (ix+SR_ATT+3),a
        ret

; ---------------------------------------------------------------- output
; The records are at fixed addresses: straight-line code, no loops. Each routine
; clears the dirty flag of the record it writes.

; effects on the PSG (SCC present): E0 -> A, E1 -> B, noise -> C
sndp_out_psg_sfx:
        xor a
        ld (sndp_sfx+SR_DIRTY),a
        out (0A0h),a
        ld a,(sndp_sfx+SR_Q)
        out (0A1h),a            ; R0, R1: period of A
        ld a,1
        out (0A0h),a
        ld a,(sndp_sfx+SR_Q+1)
        out (0A1h),a
        ld a,2
        out (0A0h),a
        ld a,(sndp_sfx+SR_Q+2)
        out (0A1h),a            ; R2, R3: period of B
        ld a,3
        out (0A0h),a
        ld a,(sndp_sfx+SR_Q+3)
        out (0A1h),a
        ld a,6
        out (0A0h),a
        ld a,(sndp_sfx+SR_NP)
        out (0A1h),a            ; R6: noise period
        ld a,7
        out (0A0h),a
        ld a,09Ch               ; tone A, B and noise C on (port B out, port A in)
        out (0A1h),a
        ld h,psg_vol>>8
        ld a,8
        out (0A0h),a
        ld a,(sndp_sfx+SR_ATT)
        or psg_vol&255
        ld l,a
        ld a,(hl)
        out (0A1h),a            ; R8-R10: volumes
        ld a,9
        out (0A0h),a
        ld a,(sndp_sfx+SR_ATT+1)
        or psg_vol&255
        ld l,a
        ld a,(hl)
        out (0A1h),a
        ld a,10
        out (0A0h),a
        ld a,(sndp_sfx+SR_ATT+2)
        or psg_vol&255
        ld l,a
        ld a,(hl)
        out (0A1h),a
        ret

; no SCC: melody M2 -> A, bass M0 -> B, effects on C (tone E0 and/or noise)
sndp_out_psg_only:
        xor a
        ld (sndp_mus+SR_DIRTY),a
        ld (sndp_sfx+SR_DIRTY),a
        out (0A0h),a
        ld a,(sndp_mus+SR_Q+4)
        out (0A1h),a            ; R0, R1: M2
        ld a,1
        out (0A0h),a
        ld a,(sndp_mus+SR_Q+5)
        out (0A1h),a
        ld a,2
        out (0A0h),a
        ld a,(sndp_mus+SR_Q)
        out (0A1h),a            ; R2, R3: M0
        ld a,3
        out (0A0h),a
        ld a,(sndp_mus+SR_Q+1)
        out (0A1h),a
        ld a,4
        out (0A0h),a
        ld a,(sndp_sfx+SR_Q)
        out (0A1h),a            ; R4, R5: E0
        ld a,5
        out (0A0h),a
        ld a,(sndp_sfx+SR_Q+1)
        out (0A1h),a
        ld a,6
        out (0A0h),a
        ld a,(sndp_sfx+SR_NP)
        out (0A1h),a            ; R6: noise period
        ld h,psg_vol>>8
        ld a,8
        out (0A0h),a
        ld a,(sndp_mus+SR_ATT+2)
        or psg_vol&255
        ld l,a
        ld a,(hl)
        out (0A1h),a            ; R8: M2
        ld a,9
        out (0A0h),a
        ld a,(sndp_mus+SR_ATT)
        or psg_vol&255
        ld l,a
        ld a,(hl)
        out (0A1h),a            ; R9: M0
        ; channel C: the louder attenuation of E0 and the noise
        ld a,(sndp_sfx+SR_ATT)
        ld d,a
        ld a,(sndp_sfx+SR_ATT+2)
        cp d
        jr c,.lo
        ld a,d
.lo:    or psg_vol&255
        ld l,a
        ld a,10
        out (0A0h),a
        ld a,(hl)
        out (0A1h),a            ; R10
        ld b,0BCh               ; tone A, B on; C and noise off
        ld a,d
        cp 15
        jr z,.nt
        res 2,b                 ; tone C on
.nt:    ld a,(sndp_sfx+SR_ATT+2)
        cp 15
        jr z,.nn
        res 5,b                 ; noise C on
.nn:    ld a,7
        out (0A0h),a
        ld a,b
        out (0A1h),a            ; R7
        ret

; music on the SCC
sndp_out_scc:
        xor a
        ld (sndp_mus+SR_DIRTY),a
        ld a,(scc_slot)
        ld hl,cart_slot
        cp (hl)
        jr nz,sndp_scc_other
        ; this cartridge: $3F at $9000 maps the SCC registers at $9800
        ld a,03Fh
        ld (KSCC_B2),a
        call scc_write
        jp sndp_restore_p2

; another slot: page 2 := SCC slot (and its subslot), write, restore
sndp_scc_other:
        in a,(0A8h)
        ld (scc_a8),a
        ld a,(scc_slot)
        and 3
        ld c,a                  ; primary
        rrca
        rrca
        rrca
        rrca
        ld b,a                  ; primary << 4 (bits 5-4)
        ld a,(scc_a8)
        and 0CFh
        or b
        ld (scc_a8n),a
        ld a,(scc_slot)
        bit 7,a
        jr z,.prim
        ; expanded: page 3 := that primary slot to write its subslot register
        ld a,c
        rrca
        rrca                    ; primary << 6
        ld b,a
        ld a,(scc_a8n)
        and 03Fh
        or b
        ld (scc_a8p3),a
        out (0A8h),a
        ld a,(0FFFFh)
        cpl
        ld (scc_sub),a
        and 0CFh
        ld b,a
        ld a,(scc_slot)
        and 00Ch                ; subslot << 2
        rlca
        rlca                    ; subslot << 4
        or b
        ld (0FFFFh),a
.prim:  ld a,(scc_a8n)
        out (0A8h),a
        call scc_write
        ld a,(scc_slot)
        bit 7,a
        jr z,.back
        ld a,(scc_a8p3)
        out (0A8h),a
        ld a,(scc_sub)
        ld (0FFFFh),a
.back:  ld a,(scc_a8)
        out (0A8h),a
        ret

; SCC at $9880: a frequency (Q - 1) only when it changed (writing it restarts
; the waveform), the 4 volumes, channels 1-4 on
scc_write:
        ld hl,(sndp_mus+SR_Q)
        dec hl
        ld de,(scc_last)
        or a
        sbc hl,de
        jr z,.f0
        add hl,de
        ld (scc_last),hl
        ld (09880h),hl
.f0:    ld hl,(sndp_mus+SR_Q+2)
        dec hl
        ld de,(scc_last+2)
        or a
        sbc hl,de
        jr z,.f1
        add hl,de
        ld (scc_last+2),hl
        ld (09882h),hl
.f1:    ld hl,(sndp_mus+SR_Q+4)
        dec hl
        ld de,(scc_last+4)
        or a
        sbc hl,de
        jr z,.f2
        add hl,de
        ld (scc_last+4),hl
        ld (09884h),hl
.f2:    ld hl,(sndp_mus+SR_Q+6)
        dec hl
        ld de,(scc_last+6)
        or a
        sbc hl,de
        jr z,.f3
        add hl,de
        ld (scc_last+6),hl
        ld (09886h),hl
.f3:    ld h,scc_vol>>8
        ld a,(sndp_mus+SR_ATT)
        or scc_vol&255
        ld l,a
        ld a,(hl)
        ld (0988Ah),a
        ld a,(sndp_mus+SR_ATT+1)
        or scc_vol&255
        ld l,a
        ld a,(hl)
        ld (0988Bh),a
        ld a,(sndp_mus+SR_ATT+2)
        or scc_vol&255
        ld l,a
        ld a,(hl)
        ld (0988Ch),a
        ld a,(sndp_mus+SR_ATT+3)
        or scc_vol&255
        ld l,a
        ld a,(hl)
        ld (0988Dh),a
        ld a,00Fh
        ld (0988Fh),a
        ret

scc_last:       ds 8,0FFh           ; frequencies last written (page 0 RAM)
scc_a8:         db 0
scc_a8n:        db 0
scc_a8p3:       db 0
scc_sub:        db 0

; SN76489 attenuation (2 dB steps) -> SCC volume (linear) / PSG volume (~3 dB steps)
; (16-aligned: indexed with OR)
        align 16
scc_vol:        db 15,12,9,8,6,5,4,3,2,2,2,1,1,1,1,0
psg_vol:        db 15,14,14,13,12,12,11,10,10,9,8,8,7,6,6,0

; boot: PSG silent, players stopped (the records are in the zeroed reserved area)
sndp_init:
        ld a,7
        out (0A0h),a
        ld a,0BFh
        out (0A1h),a            ; mixer: all off (port B out, port A in)
        ld a,8
        out (0A0h),a
        xor a
        out (0A1h),a
        ld a,9
        out (0A0h),a
        xor a
        out (0A1h),a
        ld a,10
        out (0A0h),a
        xor a
        out (0A1h),a
        ld a,BANK_CODE2
        ld (p2_cur),a
        jp sndp_stop_all
