#!/usr/bin/env python3
"""Static MC6809 -> Z80 translator for the Shao-lin's Road port.

It reads the same inputs as dis6809.py of the arcade data (ROM, coverage, annotations),
reuses its analysis (instructions, labels, data regions, symbols) and writes
Z80 sources for sjasm 0.42c:

  OUT/xl_equ.asm     symbols: RAM/IO equates (identity mapped), data labels
  OUT/xl_code.asm    translated code, one block per chunk (see placement)
  OUT/xl_data.asm    the arcade data at its original addresses (big-endian words)
  OUT/xl_chunks.json chunk list for the placement step

Register mapping: A->A, B->B, D->A:B, X->IX, Y->IY, U->DE, S->SP.
Scratch: C, H, L. DP is the constant $2A. Memory is identity mapped and
big-endian (16-bit accesses are done byte by byte, high byte first).

Flags: a backward liveness analysis tells, for every 6809 instruction,
which of N Z V C are read later. The emitter only synthesises the flags that
are live, and preserves flags that pass through.

usage: xlat6809.py ROM COVERAGE ANNDIR OUTDIR
"""
import sys, os, json, re, glob
sys.path.insert(0, os.path.join(os.environ.get('ARCADE', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'arcade')), 'tools'))
import dis6809 as D

N, Z, V, C = 'N', 'Z', 'V', 'C'
ALL = frozenset('NZVC')

# Code ranges that are not translated (sound driver: replaced by the port's
# own sound; service mode and boot test: not ported; coins, credits and the
# cocktail player 2 controls: the port has no coins and an upright cabinet).
# References to labels inside them resolve to a stub.
EXCLUDE = [(0xA6D0, 0xAE60),
           (0xB453, 0xBA3B),    # service mode, its screen helpers, boot test
           (0x6248, 0x6250),    # irq_service
           (0x6290, 0x6335),    # do_coins .. coin_add: coin counters, coins, credits
           (0x634C, 0x635E),    # set_flip_p1, set_flip (flip screen)
           (0x64E2, 0x650A),    # credit_check, attract_restart (on a new credit)
           (0x6E96, 0x6E9B),    # read_ctrl_p2 (cocktail / dual controls)
           (0x8F92, 0x8FA0),    # spr_flip_update (cocktail player 2, flip screen)
           (0xAED5, 0xAEDB),    # sfx_coin
           (0x64D2, 0x64D9)]    # tcw_one_or_two: "ONE OR TWO PLAYERS"
# Instruction ranges replaced by nothing (boot delay loops, code replaced by
# the runtime, and the branches of features the port does not have)
SKIP = [(0x600D, 0x601A), (0x607C, 0x608D), (0x716A, 0x71BD),
        (0x601A, 0x6069),   # init_game: colour RAM clear and the crosshatch test grid
        (0x6253, 0x626B), (0x68E9, 0x68F7), (0x8FA4, 0x8FF6),
        (0x6A18, 0x6A20), (0x726B, 0x72CC), (0x6EBD, 0x6EDB),
        (0xA5EB, 0xA620), (0x9D52, 0x9D60), (0xAFDE, 0xB020),
        # fixed settings (no DIP switches, see OVERRIDE $6101)
        (0x6104, 0x619C),
        # no service mode, no coins
        (0x621E, 0x6224), (0x6233, 0x6236),
        # no flip screen, no cocktail cabinet: the calls of set_flip_p1 and
        # spr_flip_update, the flip of player 2's turn, player 2's controls
        (0x6335, 0x6337), (0x63E9, 0x63EC), (0x6538, 0x653B), (0x65AF, 0x65B2),
        (0x686C, 0x686F), (0x6A45, 0x6A48), (0x6AD2, 0x6AD5), (0x6DE6, 0x6DE9),
        (0x6787, 0x6798), (0x6E83, 0x6E91),
        # no credits: the start buttons always start a game, the title always
        # shows "PRESS START / ONE OR TWO PLAYERS", no credit line
        (0x6366, 0x636C), (0x6377, 0x6381), (0x6385, 0x6393), (0x63B0, 0x63B4),
        (0x63BD, 0x63D9), (0x6410, 0x6416), (0x64C6, 0x64CB), (0x650A, 0x6510),
        (0x659E, 0x65A6), (0x7347, 0x735A),
        # sounds always on in the attract demo
        (0xAE60, 0xAE6E),
        (0x6C0F, 0x6C1A)]   # clear_actors (OVERRIDE)
# Hand-written replacements for single instructions (the rest of the routine is
# in SKIP). bin_to_bcd returns through a return address read from the stack
# and leaves its result on the stack: done by the runtime instead.
OVERRIDE = {0x7168: ['jp xl_bin_to_bcd'],
            0x6250: ['jp xl_ov_copy_sprites'],      # copy_sprites
            0x68E6: ['call xl_ov_camshift'],        # camera_update: shift the 24 slots
            0x8FA1: ['jp xl_ov_build_sprites'],     # build_sprites + slot_to_sprite
            0x6A14: ['jp xl_ov_copycol'],           # copy_map_column loop: ring only (map already in VRAM)
            0x7268: ['jp xl_ov_scenery'],           # job_scenery: upload the whole map
            0x6EBB: ['call xl_ov_bgclear'],         # job_bg_clear: direct plane B blank
            0xA5E8: ['jp xl_ov_gauge'],             # draw_enemy_gauge: store the HUD cells only when they change
            0x9D4F: ['jp xl_ov_level_params'],      # get_level_params: 7 * level without mul
            0xAFDC: ['jp xl_ov_find_floor'],        # find_floor_at: platform search, 16-bit compares in HL/DE
            0x60A4: ['xor a'],                      # game_mode 0 at boot (no service mode)
            # fixed settings instead of the DIP switches: 3 lives, extra life at
            # 40000 then every 80000, difficulty hard (base level 6)
            0x6101: ['ld a,3', 'ld (lives_start),a', 'ld a,6', 'ld (difficulty),a',
                     'ld a,1', 'ld (bonus_every_on),a', 'ld hl,00400h', 'ld (bonus_first),hl',
                     'ld hl,00800h', 'ld (bonus_every),hl', 'xor a', 'ld (bonus_first_lo),a',
                     'ld (bonus_every_lo),a'],
            # START1 starts a one player game in hard mode (level 6), START2 in medium (4)
            0x6375: ['ld a,6', 'ld (difficulty),a', 'xor a', 'ld b,a', 'jp attract_start_game'],
            0x640E: ['jp title_logo_credit'],       # title: always the "PRESS START" screen
            0x6393: ['ld a,4', 'ld (difficulty),a', 'xor a', 'ld b,a'],     # START2: medium, still one player
            0x7345: ['ret'],                        # job 10, credit line: nothing
            0x6C0C: ['jp xl_ov_clear_actors'],      # clear_actors: ldir, and the V9990 sprites hidden
            # "GAME OVER": flag it (go_msg, $20A4) for build_sprites: no sprite over it
            0x6BBF: ['ld a,1', 'ld (020A4h),a', 'ld de,txt_gameover_bonus']}
# Arcade data changed for the port: {address: [byte expressions]}.
def _w(v):
    return ['(%s)>>8' % v, '(%s)&255' % v]
def _name(t):
    return ['%d' % (ord(c) - 0x30) if c != ' ' else '16' for c in t]
DATA_PATCH = {
    # default ranking, names of the first six entries (3 tile codes each)
    0xBABD: _name('MSX'), 0xBAC5: _name('BTV'), 0xBACD: _name('DI '),
    0xBAD5: _name('HLT'), 0xBADD: _name('KON'), 0xBAE5: _name('AMI'),
    # title screen: its texts one game row higher (screen address - 1)
    0xBEAB: _w('VIDEORAM+028Dh'),                           # PRESS START
    0xBEB9: _w('VIDEORAM+02CFh'),                           # the text of the two modes
    0xBEBB: [str(ord(c)) for c in '1@HARD@2@MEDIUM?'],      # "1 HARD 2 MEDIUM" (was ONE PLAYER ONLY)
    0xBECB: _w('VIDEORAM+02EFh'),                           # ONE OR TWO PLAYERS
    0xC114: _w('VIDEORAM+0393h'),                           # 1ST BONUS AFTER + number
    0xC0F6: _w('VIDEORAM+0396h'),                           # AND EVERY BONUS + number
    # the logo and the copyright are shared with the ranking screen: the title
    # prints its own copies (runtime), and the "MSX V9990 DIHALT 2026" line, through
    # the text table entries of texts the port does not use (6 deposit coin,
    # 8 RAM check, 9 ROM check)
    0xBE78: _w('txt_title_credit'), 0xBE7C: _w('txt_title_logo'), 0xBE7E: _w('txt_title_copyright'),
    0xBC33: ['1', '8'], 0xBC35: ['1', '9'], 0xBC39: ['1', '6'],   # d_title_jobs: texts 8, 9, 6
}
# Data that is not needed at run time (sound engine data, service tables,
# unused ROM). Everything else keeps its arcade address.
DATA_DROP = [(0xA6D0, 0xAE60), (0xE51E, 0xF7F4), (0xF8E5, 0xFC6B), (0xFC6B, 0x10000)]

# Arcade I/O (memory mapped below $2800)
IO_W = {0x0000: 'ignore', 0x0100: 'ignore', 0x0300: 'ignore', 0x0400: 'ignore',
        0x0800: 'ignore', 0x1000: 'ignore', 0x1800: 'io_palbank', 0x2000: 'io_scroll'}
IO_R = {0x0200: 'io_vpos', 0x0700: 'io_system', 0x0701: 'io_p1', 0x0702: 'io_p2'}
DIP_R = (0x0500, 0x0600, 0x0703)    # no DIP switches: any read left is an error

def excluded(a):
    return any(s <= a < e for s, e in EXCLUDE)

def skipped(a):
    return any(s <= a < e for s, e in SKIP)

def hx(v):
    v &= 0xFFFF
    return '0%04Xh' % v

def h8(v):
    return '0%02Xh' % (v & 0xFF)

RESERVED = {'a', 'b', 'c', 'd', 'e', 'h', 'l', 'af', 'bc', 'de', 'hl', 'ix', 'iy', 'sp',
            'i', 'r', 'nz', 'z', 'nc', 'po', 'pe', 'p', 'm', 'ixh', 'ixl', 'iyh', 'iyl',
            'end', 'org', 'page', 'if', 'else', 'endif', 'db', 'dw', 'ds', 'equ', 'macro',
            'endm', 'include', 'incbin', 'defpage', 'output', 'code', 'data', 'high', 'low'}

def zname(n):
    """6809 symbol -> sjasm-safe symbol."""
    if n.lower() in RESERVED:
        return 'g_' + n
    return n

# ------------------------------------------------------------- flag model
def flag_use_def(ins):
    """Return (use, define) flag sets of a 6809 instruction."""
    mn = ins.mn
    base = mn.rstrip('ab') if mn not in ('sub', 'sbc') else mn
    if mn in ('ldd', 'ldx', 'ldy', 'ldu', 'lds', 'std', 'stx', 'sty', 'stu', 'sts'):
        return set(), {N, Z, V}
    if re.match(r'^(ld|st)[ab]$', mn) or re.match(r'^(and|or|eor|bit)[ab]$', mn):
        return set(), {N, Z, V}
    if re.match(r'^(tst)[ab]?$', mn):
        return set(), {N, Z, V}
    if re.match(r'^(clr|com)[ab]?$', mn):
        return set(), {N, Z, V, C}
    if re.match(r'^(add|sub|cmp|neg)[ab]?$', mn) or mn in ('addd', 'subd', 'cmpd', 'cmpx', 'cmpy', 'cmpu', 'cmps'):
        return set(), {N, Z, V, C}
    if re.match(r'^(adc|sbc)[ab]$', mn):
        return {C}, {N, Z, V, C}
    if re.match(r'^(inc|dec)[ab]?$', mn):
        return set(), {N, Z, V}
    if re.match(r'^(lsr|asl|asr)[ab]?$', mn):
        return set(), {N, Z, V, C}
    if re.match(r'^(rol|ror)[ab]?$', mn):
        return {C}, {N, Z, V, C}
    if mn in ('leax', 'leay'):
        return set(), {Z}
    if mn == 'mul':
        return set(), {Z, C}
    if mn == 'sex':
        return set(), {N, Z}
    if mn == 'daa':
        return {C}, {N, Z, V, C}
    if mn in ('jsr', 'bsr', 'lbsr'):
        return set(), set(ALL)
    if mn == 'rts' or (mn in ('puls',) and ins.opnd & 0x80):
        return {C, Z}, set()
    if mn in ('orcc', 'andcc'):
        return set(), ({C} if ins.opnd & 1 or (mn == 'andcc' and not ins.opnd & 1) else set())
    br = {'beq': {Z}, 'bne': {Z}, 'bcc': {C}, 'bcs': {C}, 'bmi': {N}, 'bpl': {N},
          'bvs': {V}, 'bvc': {V}, 'bhi': {C, Z}, 'bls': {C, Z}, 'bge': {N, V},
          'blt': {N, V}, 'bgt': {N, V, Z}, 'ble': {N, V, Z}}
    b = mn[1:] if mn.startswith('lb') else mn
    if b in br:
        return set(br[b]), set()
    return set(), set()

V_LOGIC = re.compile(r'^(ld|st|and|or|eor|bit|tst|clr|com)[abdxyus]?$')

class Xlat:
    def __init__(self, dis):
        self.d = dis
        self.ins = dis.ins
        self.warn = []
        self.extra_labels = {}      # addr -> name for labels created by the translator
        self.dropped_labels = []
        self.data_labels = []
        self.lbl_counter = 0

    # --------------------------------------------------------- analysis
    def succ(self, a):
        ins = self.ins[a]
        out = []
        if not D.is_terminal(ins):
            nxt = a + ins.len
            if nxt in self.ins:
                out.append(nxt)
        if ins.target is not None and ins.target in self.ins and ins.mn not in ('bsr', 'lbsr'):
            out.append(ins.target)
        if ins.mn == 'jmp' and ins.mode == 'ext' and ins.opnd in self.ins:
            out.append(ins.opnd)
        return out

    def liveness(self):
        addrs = sorted(self.ins)
        self.ud = {a: flag_use_def(self.ins[a]) for a in addrs}
        live_in = {a: set() for a in addrs}
        live_out = {a: set() for a in addrs}
        succs = {a: self.succ(a) for a in addrs}
        changed = True
        while changed:
            changed = False
            for a in reversed(addrs):
                ins = self.ins[a]
                lo = set()
                for s in succs[a]:
                    lo |= live_in[s]
                if ins.mn in ('rts', 'rti') or (ins.mn == 'puls' and ins.opnd & 0x80):
                    lo |= {C, Z}
                use, df = self.ud[a]
                li = use | (lo - df)
                if lo != live_out[a] or li != live_in[a]:
                    live_out[a], live_in[a] = lo, li
                    changed = True
        self.live_out = live_out

    def v_source_logic(self, a):
        """For a signed branch at a: True if the flags come from an instruction
        with V=0 (load/store/logic), False if arithmetic, None if unknown."""
        addrs = self.sorted_addrs
        i = self.addr_index[a] - 1
        while i >= 0:
            p = self.ins[addrs[i]]
            if p.addr + p.len != addrs[i + 1]:
                return None
            use, df = self.ud[p.addr]
            if V in df or N in df:
                return bool(V_LOGIC.match(p.mn))
            if self.d.name(addrs[i + 1]) and addrs[i + 1] != a:
                return None
            i -= 1
        return None

    # --------------------------------------------------------- symbols
    def sym(self, v):
        """Symbolic text for an absolute address (identity mapped)."""
        v &= 0xFFFF
        if D.BASE <= v < 0x10000:
            if excluded(v) and v in self.ins:
                return 'xl_stub'
            n = self.d.name(v)
            if n:
                return zname(n)
            return hx(v)
        if v in self.d.A.equ:
            return zname(self.d.A.equ[v])
        if 0x3100 <= v < 0x3400:
            n, off = (v - 0x3100) // 32, (v - 0x3100) % 32
            return 'slot%d+%d' % (n, off) if off else 'slot%d' % n
        if 0x3800 <= v < 0x4000:
            base, nm = (0x3C00, 'VIDEORAM') if v >= 0x3C00 else (0x3800, 'COLORRAM')
            return '%s+%s' % (nm, hx(v - base)) if v != base else nm
        return hx(v)

    def imm16(self, ins):
        v = ins.opnd
        if ins.addr in self.d.A.num:
            return hx(v)
        if ins.mn in ('ldx', 'ldy', 'ldu', 'lds', 'cmpx', 'cmpy', 'cmpu', 'cmps'):
            if (D.BASE <= v and self.d.name(v)) or 0x2800 <= v < 0x4000 or v in self.d.A.equ and v >= 0x2800:
                return self.sym(v)
        return hx(v)

    def newlabel(self):
        self.lbl_counter += 1
        return '.x%d' % self.lbl_counter

    # --------------------------------------------------------- operands
    def operand(self, ins, flags_in_use, allow_a=False):
        """Return (pre, op, post) for the memory operand of ins.
        op is '(ix+d)', '(iy+d)', '(hl)', or with allow_a also '(de)' or '(nnnn)'.
        pre may clobber flags only when flags_in_use is empty (else it is wrapped)."""
        mode = ins.mode
        pre, post = [], []
        if mode in ('dir', 'ext'):
            s = self.sym(ins.opnd)
            if allow_a:
                return pre, '(%s)' % s, post
            return ['ld hl,%s' % s], '(hl)', post
        k, reg, off, ind = ins.idx
        clob = False
        if not ind:
            if k in ('off5', 'off8', 'zero') and reg in ('x', 'y'):
                d = 0 if k == 'zero' else off
                r = 'ix' if reg == 'x' else 'iy'
                return pre, '(%s%+d)' % (r, d), post
            if k == 'off16' and reg in ('x', 'y') and -128 <= off <= 127:
                r = 'ix' if reg == 'x' else 'iy'
                return pre, '(%s%+d)' % (r, off), post
            if k in ('inc1', 'inc2', 'dec1', 'dec2') and reg in ('x', 'y'):
                r = 'ix' if reg == 'x' else 'iy'
                n = 1 if k in ('inc1', 'dec1') else 2
                if k.startswith('inc'):
                    return pre, '(%s+0)' % r, ['inc %s' % r] * n
                return ['dec %s' % r] * n, '(%s+0)' % r, post
            if reg == 'u':
                if k == 'zero':
                    if allow_a:
                        return pre, '(de)', post
                    return ['ld h,d', 'ld l,e'], '(hl)', post
                if k in ('inc1', 'inc2'):
                    n = 1 if k == 'inc1' else 2
                    if allow_a and n == 1:
                        return pre, '(de)', ['inc de']
                    return ['ld h,d', 'ld l,e'], '(hl)', ['inc de'] * n
                if k in ('dec1', 'dec2'):
                    n = 1 if k == 'dec1' else 2
                    return ['dec de'] * n + ['ld h,d', 'ld l,e'], '(hl)', post
                if k in ('off5', 'off8', 'off16'):
                    if -3 <= off <= 3:
                        return ['ld h,d', 'ld l,e'] + (['inc hl'] * off if off > 0 else ['dec hl'] * (-off)), '(hl)', post
                    pre = ['ld hl,%s' % self.off(off), 'add hl,de']
                    clob = True
            if reg == 's':
                if k in ('zero', 'off5', 'off8', 'off16') and 0 <= (0 if k == 'zero' else off) <= 6:
                    n = 0 if k == 'zero' else off
                    return ['ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)'] + ['inc hl'] * n, '(hl)', post
                if k in ('off5', 'off8', 'off16'):
                    pre = ['ld hl,%s' % self.off(off), 'add hl,sp']
                    clob = True
                elif k == 'inc1':
                    return ['ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)'], '(hl)', ['inc sp']
                elif k == 'inc2':
                    return ['ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)'], '(hl)', ['inc sp', 'inc sp']
                elif k == 'dec1':
                    return ['dec sp', 'ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)'], '(hl)', post
                elif k == 'dec2':
                    return ['dec sp', 'dec sp', 'ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)'], '(hl)', post
            if k == 'off16' and reg in ('x', 'y'):
                r = 'ix' if reg == 'x' else 'iy'
                pre = ['push de', 'push %s' % r, 'pop de', 'ld hl,%s' % self.off(off), 'add hl,de', 'pop de']
                clob = True
            if k in ('pcr8', 'pcr16'):
                s = self.sym(off)
                if allow_a:
                    return pre, '(%s)' % s, post
                return ['ld hl,%s' % s], '(hl)', post
            if k in ('acca', 'accb', 'accd'):
                pre = self.acc_ea(k, reg)
                clob = False       # acc_ea preserves AF itself
            if not pre:
                raise ValueError('operand %s at %04X' % (str(ins.idx), ins.addr))
        else:
            # indirect: compute the pointer address in HL, then load the pointer
            if k == 'extind':
                pre = ['ld hl,%s' % self.sym(off)]
            elif k in ('zero', 'off5', 'off8', 'off16') and reg in ('x', 'y'):
                r = 'ix' if reg == 'x' else 'iy'
                d = 0 if k == 'zero' else off
                if -128 <= d <= 126:
                    pre = ['ld h,(%s%+d)' % (r, d), 'ld l,(%s%+d)' % (r, d + 1)]
                    return pre, '(hl)', post
                pre = ['push de', 'push %s' % r, 'pop de', 'ld hl,%s' % self.off(d), 'add hl,de', 'pop de']
                clob = True
            elif k == 'inc2' and reg in ('x', 'y'):
                r = 'ix' if reg == 'x' else 'iy'
                return ['ld h,(%s+0)' % r, 'ld l,(%s+1)' % r, 'inc %s' % r, 'inc %s' % r], '(hl)', post
            elif k in ('acca', 'accb', 'accd'):
                pre = self.acc_ea(k, reg)
            elif reg == 'u' and k in ('zero', 'off5', 'off8'):
                d = 0 if k == 'zero' else off
                pre = ['ld hl,%s' % self.off(d), 'add hl,de']
                clob = True
            elif k in ('pcr8', 'pcr16'):
                pre = ['ld hl,%s' % self.sym(off)]
            else:
                raise ValueError('indirect operand %s at %04X' % (str(ins.idx), ins.addr))
            pre = pre + ['ld c,(hl)', 'inc hl', 'ld l,(hl)', 'ld h,c']
        if clob and flags_in_use:
            pre = ['push af'] + pre + ['pop af']
        return pre, '(hl)', post

    def off(self, v):
        return ('-' + hx(-v)) if v < 0 else hx(v)

    def acc_ea(self, k, reg):
        """HL = base register + (signed A | signed B | D). Preserves AF and BC."""
        base = {'x': ['push ix', 'pop hl'], 'y': ['push iy', 'pop hl'],
                'u': ['ld h,d', 'ld l,e'], 's': ['ld hl,0', 'add hl,sp']}[reg]
        code = ['push af', 'push bc']
        if k == 'acca':
            code += ['ld c,a', 'add a,a', 'sbc a,a', 'ld b,a']
        elif k == 'accb':
            code += ['ld c,b', 'ld a,b', 'add a,a', 'sbc a,a', 'ld b,a']
        else:
            code += ['ld c,b', 'ld b,a']
        if reg == 's':
            code += ['ld hl,4', 'add hl,sp', 'add hl,bc']      # skip the two pushes
        else:
            code += base + ['add hl,bc']
        code += ['pop bc', 'pop af']
        return code

    # --------------------------------------------------------- flag helpers
    def setnz8(self, reg, keepC):
        if reg == 'a':
            return ['inc a', 'dec a'] if keepC else ['or a']
        return ['inc %s' % reg, 'dec %s' % reg]

    # --------------------------------------------------------- emitter
    def translate(self, a):
        """Z80 lines for the instruction at a."""
        ins = self.ins[a]
        lo = self.live_out.get(a, set())
        use, df = self.ud[a]
        need = df & lo
        keep = lo - df
        fin = bool(use | keep)          # flags in use while the operand is computed
        mn = ins.mn
        out = []
        try:
            out = self.emit(ins, mn, need, keep, fin)
        except Exception as e:
            self.warn.append('%04X %s: %s' % (a, mn, e))
            out = ['call xl_untranslated  ; %s' % e]
        return out

    def io_store(self, ins, src):
        """Store of register src ('a' or 'b') to an arcade I/O address."""
        h = IO_W.get(ins.opnd)
        if h is None or h == 'ignore':
            return []
        if h == 'io_scroll':
            if src == 'a':
                return ['ld (io_scroll),a']
            return ['ld c,a', 'ld a,b', 'ld (io_scroll),a', 'ld a,c']
        if h == 'io_palbank':
            if src == 'a':
                return ['ld (io_palbank),a']
            return ['ld c,a', 'ld a,b', 'ld (io_palbank),a', 'ld a,c']
        return []

    def is_io(self, ins):
        return ins.mode in ('ext', 'dir') and ins.opnd < 0x2800

    def emit(self, ins, mn, need, keep, fin):
        m = mn
        o = []
        keepC = C in keep
        # ---------------------------------------------------- 8-bit loads
        if m in ('lda', 'ldb'):
            r = m[2]
            if ins.mode == 'imm8':
                o.append('ld %s,%s' % (r, h8(ins.opnd)))
            elif self.is_io(ins):
                src = IO_R.get(ins.opnd)
                if ins.opnd in DIP_R:       # DIP switches: fixed settings instead
                    raise ValueError('read of DIP switch %04X at %04X' % (ins.opnd, ins.addr))
                if src is None:             # open bus: 0
                    o.append('ld %s,0' % r)
                elif r == 'a':
                    o.append('ld a,(%s)' % src)
                else:
                    o += ['ld hl,%s' % src, 'ld b,(hl)']
            else:
                pre, op, post = self.operand(ins, fin, allow_a=(r == 'a'))
                o += pre + ['ld %s,%s' % (r, op)] + post
            if need & {N, Z}:
                o += self.setnz8(r, keepC)
            return o
        if m in ('sta', 'stb'):
            r = m[2]
            if self.is_io(ins):
                o += self.io_store(ins, r)
            else:
                pre, op, post = self.operand(ins, fin, allow_a=(r == 'a'))
                o += pre + ['ld %s,%s' % (op, r)]
                if self.is_vram_writer(ins):
                    o += self.mark_after(ins, op)
                o += post
            if need & {N, Z}:
                o += self.setnz8(r, keepC)
            return o
        # ---------------------------------------------------- 16-bit loads
        if m in ('ldd', 'ldx', 'ldy', 'ldu', 'lds'):
            r = m[2]
            if ins.mode == 'imm16':
                v = self.imm16(ins)
                if r == 'd':
                    o += ['ld a,(%s)>>8' % v if False else 'ld a,%s' % self.hi(v), 'ld b,%s' % self.lo(v)]
                else:
                    o.append('ld %s,%s' % ({'x': 'ix', 'y': 'iy', 'u': 'de', 's': 'sp'}[r], v))
            else:
                pre, op, post = self.operand(ins, fin)
                if ins.mode not in ('dir', 'ext') and ins.idx[1] == r and ins.idx[0] in ('inc1', 'inc2') \
                        and not ins.idx[3]:
                    # ldy ,y++: the loaded value replaces the incremented register
                    post = []
                o += pre + self.load16(r, op) + post
            if need & {N, Z}:
                o += self.test16(r, keepC)
            return o
        if m in ('std', 'stx', 'sty', 'stu', 'sts'):
            r = m[2]
            pre, op, post = self.operand(ins, fin)
            if self.is_vram_writer(ins) and op == '(hl)':
                o += pre + ['push hl'] + self.store16(r, op) + ['pop hl', 'call xl_mark', 'inc hl', 'call xl_mark'] + post
            elif self.is_vram_writer(ins):
                o += pre + self.store16(r, op) + self.mark16(ins, op) + post
            else:
                o += pre + self.store16(r, op) + post
            if need & {N, Z}:
                o += self.test16(r, keepC)
            return o
        # ---------------------------------------------------- ALU 8-bit
        alu = {'add': 'add a,', 'adc': 'adc a,', 'sub': 'sub ', 'sbc': 'sbc a,',
               'and': 'and ', 'or': 'or ', 'eor': 'xor ', 'cmp': 'cp ', 'bit': 'and '}
        mm = re.match(r'^(add|adc|sub|sbc|and|or|eor|cmp|bit)([ab])$', m)
        if mm:
            opn, r = mm.group(1), mm.group(2)
            if ins.mode == 'imm8':
                pre, op, post = [], h8(ins.opnd), []
            else:
                pre, op, post = self.operand(ins, fin)
            z = alu[opn] + op
            logic = opn in ('and', 'or', 'eor', 'bit')
            o += pre
            if r == 'a':
                if opn == 'bit':
                    if keepC:
                        o += ['push af', z, 'ld c,a', 'pop af', 'inc c', 'dec c']
                    else:
                        o += ['ld c,a', z, 'ld a,c']
                elif logic and keepC:
                    o += ['push af', z, 'ld c,a', 'pop af', 'ld a,c', 'inc a', 'dec a']
                else:
                    o.append(z)
            else:
                if opn == 'bit':
                    if keepC:
                        o += ['push af', 'ld a,b', z, 'ld c,a', 'pop af', 'inc c', 'dec c']
                    else:
                        o += ['ld c,a', 'ld a,b', z, 'ld a,c']
                elif opn == 'cmp':
                    o += ['ld c,a', 'ld a,b', z, 'ld a,c']
                elif logic and keepC:
                    o += ['push af', 'ld a,b', z, 'ld b,a', 'pop af', 'inc b', 'dec b']
                else:
                    o += ['ld c,a', 'ld a,b', z, 'ld b,a', 'ld a,c']
            o += post
            return o
        # ---------------------------------------------------- ALU 16-bit
        if m in ('addd', 'subd', 'cmpd', 'cmpx', 'cmpy', 'cmpu', 'cmps'):
            return self.alu16(ins, m, need, keep, fin)
        # ---------------------------------------------------- RMW
        mm = re.match(r'^(neg|com|lsr|ror|asr|asl|rol|dec|inc|tst|clr)([ab]?)$', m)
        if mm:
            return self.rmw(ins, mm.group(1), mm.group(2), need, keep, fin)
        # ---------------------------------------------------- branches
        if ins.mode in ('rel8', 'rel16'):
            return self.branch(ins, m)
        if m == 'jmp':
            if ins.mode in ('ext', 'dir'):
                return ['jp %s' % self.sym(ins.opnd)]
            k, reg, off, ind = ins.idx
            if not ind and k == 'zero' and reg in ('x', 'y'):
                return ['jp (%s)' % ('ix' if reg == 'x' else 'iy')]
            pre, op, post = self.operand(ins, set(), )
            if op != '(hl)':
                raise ValueError('jmp operand')
            return pre + post + ['jp (hl)']
        if m == 'jsr':
            if ins.mode in ('ext', 'dir'):
                return ['call %s' % self.sym(ins.opnd)]
            k, reg, off, ind = ins.idx
            if not ind and k == 'zero' and reg in ('x', 'y'):
                return ['call xl_jp%s' % ('ix' if reg == 'x' else 'iy')]
            pre, op, post = self.operand(ins, set())
            return pre + post + ['call xl_jphl']
        if m == 'rts':
            return ['ret']
        if m == 'rti':
            return ['ret                  ; RTI: the dispatcher restores the registers']
        # ---------------------------------------------------- stack
        if m in ('pshs', 'puls', 'pshu', 'pulu'):
            return self.stack(ins, m, keep | need)
        # ---------------------------------------------------- LEA
        if m in ('leax', 'leay', 'leau', 'leas'):
            return self.lea(ins, m, need, keep)
        # ---------------------------------------------------- misc
        if m in ('tfr', 'exg'):
            return self.tfr(ins, m)
        if m == 'mul':
            return ['call xl_mul']
        if m == 'sex':
            o = ['ld a,b', 'add a,a', 'sbc a,a']
            if need & {N, Z}:
                o += self.test16('d', keepC)
            return o
        if m == 'abx':
            o = ['ld c,b', 'ld b,0', 'add ix,bc', 'ld b,c']
            if fin:
                o = ['push af'] + o + ['pop af']
            return o
        if m == 'daa':
            return ['daa']
        if m == 'nop':
            return []
        if m == 'orcc':
            o = []
            if ins.opnd & 0x10: o.append('di')
            if ins.opnd & 0x01: o.append('scf')
            return o
        if m == 'andcc':
            o = []
            if not ins.opnd & 0x10: o.append('ei')
            if not ins.opnd & 0x01: o += ['scf', 'ccf']
            return o
        if m == 'cwai':
            return ['ei', 'halt']
        if m == 'sync':
            return ['halt']
        raise ValueError('no translation for %s' % m)

    # ---- helpers for the emitter
    def hi(self, v):
        return '(%s)>>8' % v if not re.match(r'^0[0-9A-F]+h$', v) else h8(int(v[:-1], 16) >> 8)

    def lo(self, v):
        return '(%s)&255' % v if not re.match(r'^0[0-9A-F]+h$', v) else h8(int(v[:-1], 16))

    def split16(self, op):
        """High/low byte operands for a 16-bit access through op (or None)."""
        mm = re.match(r'^\((i[xy])([+-]\d+)\)$', op)
        if mm:
            d = int(mm.group(2))
            if d + 1 <= 127:
                return '(%s%+d)' % (mm.group(1), d), '(%s%+d)' % (mm.group(1), d + 1)
        return None

    def load16(self, r, op):
        s = self.split16(op)
        if r == 'd':
            if s: return ['ld a,%s' % s[0], 'ld b,%s' % s[1]]
            return ['ld a,(hl)', 'inc hl', 'ld b,(hl)']
        if r == 'u':
            if s: return ['ld d,%s' % s[0], 'ld e,%s' % s[1]]
            return ['ld d,(hl)', 'inc hl', 'ld e,(hl)']
        if s:
            seq = ['ld h,%s' % s[0], 'ld l,%s' % s[1]]
        else:
            seq = ['ld c,(hl)', 'inc hl', 'ld l,(hl)', 'ld h,c']
        if r == 'x': return seq + ['push hl', 'pop ix']
        if r == 'y': return seq + ['push hl', 'pop iy']
        if r == 's': return seq + ['ld sp,hl']
        raise ValueError(r)

    def store16(self, r, op):
        s = self.split16(op)
        if r == 'd':
            if s: return ['ld %s,a' % s[0], 'ld %s,b' % s[1]]
            return ['ld (hl),a', 'inc hl', 'ld (hl),b']
        if r == 'u':
            if s: return ['ld %s,d' % s[0], 'ld %s,e' % s[1]]
            return ['ld (hl),d', 'inc hl', 'ld (hl),e']
        rr = {'x': 'ix', 'y': 'iy'}.get(r)
        if s and rr:
            return ['push %s' % rr, 'pop hl', 'ld %s,h' % s[0], 'ld %s,l' % s[1]]
        if rr:
            # EA in HL, value in IX/IY: swap through the stack
            return ['push %s' % rr, 'ex (sp),hl', 'ld c,h', 'ex (sp),hl', 'ld (hl),c', 'inc hl',
                    'ex (sp),hl', 'ld c,l', 'ex (sp),hl', 'ld (hl),c', 'inc sp', 'inc sp']
        if r == 's':
            return ['ex de,hl', 'ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)', 'ex de,hl',
                    'ld (hl),d', 'inc hl', 'ld (hl),e', 'ld de,(xl_sptmp_u)']
        raise ValueError(r)

    def test16(self, r, keepC):
        """Set S,Z from a 16-bit register (N,Z of the 6809)."""
        if r == 'd':
            return ['call xl_tstd']
        src = {'x': ['push ix', 'pop hl'], 'y': ['push iy', 'pop hl'], 'u': ['ld h,d', 'ld l,e'],
               's': ['ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)']}[r]
        return src + ['call xl_tsthl']

    def alu16(self, ins, m, need, keep, fin):
        o = []
        # operand -> HL path or (ix+d)
        if ins.mode == 'imm16':
            src = ['ld de,%s' % self.imm16(ins)]
        else:
            pre, op, post = self.operand(ins, fin)
            s = self.split16(op)
            if s:
                src = pre + ['ld d,%s' % s[0], 'ld e,%s' % s[1]] + post
            else:
                src = pre + ['ld d,(hl)', 'inc hl', 'ld e,(hl)'] + post
        if m in ('addd', 'subd', 'cmpd'):
            o += ['push de'] + src + ['ld h,a', 'ld l,b']
            if m == 'addd':
                o += ['or a', 'adc hl,de'] if need & {N, Z, V} else ['add hl,de']
                o += ['ld a,h', 'ld b,l']
            else:
                o += ['or a', 'sbc hl,de']
                if m == 'subd':
                    o += ['ld a,h', 'ld b,l']
            o += ['pop de']
            return o
        reg = m[3]
        if reg == 'u':
            # HL = U, operand into DE (save U)
            return ['push de'] + src + ['pop hl', 'push hl', 'or a', 'sbc hl,de', 'pop de']
        load = {'x': ['push ix', 'pop hl'], 'y': ['push iy', 'pop hl'],
                's': ['ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)']}[reg]
        # the operand may be computed with HL: compute it first into DE
        return ['push de'] + src + load + ['or a', 'sbc hl,de', 'pop de']

    def rmw(self, ins, op, r, need, keep, fin):
        keepC = C in keep
        o = []
        if r == 'a':
            t = {'neg': ['neg'], 'com': ['cpl'] + (['inc a', 'dec a', 'scf'] if need else []),
                 'lsr': ['srl a'], 'asr': ['sra a'], 'asl': ['sla a'],
                 'rol': ['rl a'] if need & {N, Z} else ['rla'],
                 'ror': ['rr a'] if need & {N, Z} else ['rra'],
                 'dec': ['dec a'], 'inc': ['inc a'],
                 'tst': self.setnz8('a', keepC) if need else [],
                 'clr': ['xor a']}[op]
            return t
        if r == 'b':
            t = {'neg': ['ld c,a', 'xor a', 'sub b', 'ld b,a', 'ld a,c'],
                 'com': ['ld c,a', 'ld a,b', 'cpl', 'ld b,a', 'ld a,c'] + (['inc b', 'dec b', 'scf'] if need else []),
                 'lsr': ['srl b'], 'asr': ['sra b'], 'asl': ['sla b'], 'rol': ['rl b'], 'ror': ['rr b'],
                 'dec': ['dec b'], 'inc': ['inc b'],
                 'tst': ['inc b', 'dec b'] if need else [],
                 'clr': ['ld b,0'] + (['ld c,a', 'xor a', 'ld a,c'] if need else [])}[op]
            return t
        # memory
        if self.is_io(ins):
            if op == 'clr':
                return []         # clr of an I/O register: nothing to emulate
            return ['; I/O read-modify-write ignored']
        pre, mo, post = self.operand(ins, fin)
        o += pre
        if op in ('lsr', 'asr', 'asl', 'rol', 'ror'):
            o.append({'lsr': 'srl', 'asr': 'sra', 'asl': 'sla', 'rol': 'rl', 'ror': 'rr'}[op] + ' ' + mo)
        elif op in ('inc', 'dec'):
            o.append('%s %s' % (op, mo))
        elif op == 'clr':
            o.append('ld %s,0' % mo)
            if need:
                o += ['ld c,a', 'xor a', 'ld a,c']
        elif op == 'tst':
            o += ['ld c,%s' % mo, 'inc c', 'dec c']
        elif op == 'neg':
            o += ['ld c,a', 'xor a', 'sub %s' % mo, 'ld %s,a' % mo, 'ld a,c']
        elif op == 'com':
            o += ['ld c,a', 'ld a,%s' % mo, 'cpl', 'ld %s,a' % mo] + (['or a', 'scf'] if need else []) + ['ld a,c']
        if op not in ('tst',) and self.is_vram_writer(ins):
            o += self.mark_after(ins, mo)
        o += post
        return o

    def branch(self, ins, m):
        t = self.sym(ins.target)
        b = m[1:] if m.startswith('lb') else m
        simple = {'bra': 'jp %s', 'beq': 'jp z,%s', 'bne': 'jp nz,%s', 'bcc': 'jp nc,%s',
                  'bcs': 'jp c,%s', 'bmi': 'jp m,%s', 'bpl': 'jp p,%s', 'bvs': 'jp pe,%s', 'bvc': 'jp po,%s'}
        if b in ('bsr',) or m == 'lbsr':
            return ['call %s' % t]
        if b == 'brn':
            return []
        if b in simple:
            if b in ('bvs', 'bvc'):
                self.warn.append('%04X %s: overflow test' % (ins.addr, m))
            return [simple[b] % t]
        L = self.newlabel()
        if b == 'bhi':
            return ['jr c,%s' % L, 'jp nz,%s' % t, L]
        if b == 'bls':
            return ['jp c,%s' % t, 'jp z,%s' % t]
        logic = self.v_source_logic(ins.addr)
        if logic:
            # V = 0: N alone decides
            if b == 'bge': return ['jp p,%s' % t]
            if b == 'blt': return ['jp m,%s' % t]
            if b == 'bgt': return ['jr z,%s' % L, 'jp p,%s' % t, L]
            if b == 'ble': return ['jp z,%s' % t, 'jp m,%s' % t]
        if logic is None:
            self.warn.append('%04X %s: flag source unknown, full signed test' % (ins.addr, m))
        L2 = self.newlabel()
        # less = S xor V
        if b == 'blt':
            return ['jp pe,%s' % L, 'jp m,%s' % t, 'jr %s' % L2, L, 'jp p,%s' % t, L2]
        if b == 'bge':
            return ['jp pe,%s' % L, 'jp p,%s' % t, 'jr %s' % L2, L, 'jp m,%s' % t, L2]
        if b == 'ble':
            return ['jp z,%s' % t, 'jp pe,%s' % L, 'jp m,%s' % t, 'jr %s' % L2, L, 'jp p,%s' % t, L2]
        if b == 'bgt':
            return ['jr z,%s' % L2, 'jp pe,%s' % L, 'jp p,%s' % t, 'jr %s' % L2, L, 'jp m,%s' % t, L2]
        raise ValueError(m)

    def stack(self, ins, m, flags_live):
        regs6809 = ['cc', 'a', 'b', 'dp', 'x', 'y', 'us', 'pc']
        bits = [(i, regs6809[i]) for i in range(8) if ins.opnd & (1 << i)]
        o = []
        if m == 'pshs':
            for i, r in sorted(bits, reverse=True):     # pc first ... cc last
                if r == 'pc': raise ValueError('pshs pc')
                if r == 'us': o.append('push de')
                elif r == 'y': o.append('push iy')
                elif r == 'x': o.append('push ix')
                elif r == 'dp': o += ['ld c,02Ah', 'push bc', 'inc sp']
                elif r == 'b': o += ['push bc', 'inc sp']
                elif r == 'a': o += ['push af', 'inc sp']
                elif r == 'cc': o += ['push af', 'dec sp', 'pop bc', 'inc sp', 'push bc', 'inc sp'] if False else ['push af', 'inc sp', 'push af', 'pop hl', 'dec sp', 'ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)', 'inc sp'] if False else ['call xl_push_cc']
            return o
        if m == 'puls':
            ret = False
            for i, r in sorted(bits):
                if r == 'pc': ret = True
                elif r == 'us': o.append('pop de')
                elif r == 'y': o.append('pop iy')
                elif r == 'x': o.append('pop ix')
                elif r == 'dp': o += ['dec sp', 'pop hl']
                elif r == 'b': o += ['dec sp', 'pop hl', 'ld b,h']
                elif r == 'a': o += ['dec sp', 'pop hl', 'ld a,h']
                elif r == 'cc': o += ['dec sp', 'pop hl', 'call xl_pull_cc']
            if ret: o.append('ret')
            return o
        # U stack: big-endian memory at DE
        if m == 'pshu':
            for i, r in sorted(bits, reverse=True):
                if r in ('x', 'y'):
                    o += ['push %s' % ('ix' if r == 'x' else 'iy'), 'pop hl',
                          'ex de,hl', 'dec hl', 'ld (hl),e', 'dec hl', 'ld (hl),d', 'ex de,hl']
                elif r == 'b': o += ['dec de', 'ld h,d', 'ld l,e', 'ld (hl),b']
                elif r == 'a': o += ['dec de', 'ld (de),a']
                else: raise ValueError('pshu %s' % r)
            return o
        if m == 'pulu':
            for i, r in sorted(bits):
                if r in ('x', 'y'):
                    o += ['ex de,hl', 'ld d,(hl)', 'inc hl', 'ld e,(hl)', 'inc hl', 'ex de,hl',
                          'push hl', 'pop %s' % ('ix' if r == 'x' else 'iy')]
                elif r == 'b': o += ['ld h,d', 'ld l,e', 'ld b,(hl)', 'inc de']
                elif r == 'a': o += ['ld a,(de)', 'inc de']
                else: raise ValueError('pulu %s' % r)
            return o

    def lea(self, ins, m, need, keep):
        r = m[3]
        k, reg, off, ind = ins.idx
        o = []
        rr = {'x': 'ix', 'y': 'iy'}
        flags_live = bool(keep) or bool(need)
        if not ind and k in ('off5', 'off8', 'off16', 'zero') and reg == r:
            d = 0 if k == 'zero' else off
            if r in ('x', 'y') and -3 <= d <= 3:
                o += ['inc %s' % rr[r]] * d if d > 0 else ['dec %s' % rr[r]] * (-d)
            elif r == 'u' and -3 <= d <= 3:
                o += ['inc de'] * d if d > 0 else ['dec de'] * (-d)
            elif r == 's' and -6 <= d <= 6:
                o += ['inc sp'] * d if d > 0 else ['dec sp'] * (-d)
            elif r in ('x', 'y'):
                body = ['push de', 'ld de,%s' % self.off(d), 'add %s,de' % rr[r], 'pop de']
                o += (['push af'] + body + ['pop af']) if keep else body
            elif r == 'u':
                body = ['ld hl,%s' % self.off(d), 'add hl,de', 'ex de,hl']
                o += (['push af'] + body + ['pop af']) if keep else body
            else:
                body = ['ld hl,%s' % self.off(d), 'add hl,sp', 'ld sp,hl']
                o += (['push af'] + body + ['pop af']) if keep else body
        else:
            pre, op, post = self.operand(ins, flags_live)
            if op != '(hl)':
                mm = re.match(r'^\((i[xy])([+-]\d+)\)$', op)
                if mm:
                    body = ['push de', 'push %s' % mm.group(1), 'pop hl', 'ld de,%s' % self.off(int(mm.group(2))), 'add hl,de', 'pop de']
                    pre = (['push af'] + body + ['pop af']) if flags_live else body
                elif op == '(de)':
                    pre = ['ld h,d', 'ld l,e']
                else:
                    raise ValueError('lea operand %s' % op)
            o += pre + post
            o += {'x': ['push hl', 'pop ix'], 'y': ['push hl', 'pop iy'],
                  'u': ['ex de,hl'], 's': ['ld sp,hl']}[r]
        if Z in need and r in ('x', 'y'):
            o += ['push %s' % rr[r], 'pop hl', 'call xl_tsthl']
        return o

    def tfr(self, ins, m):
        a, b = ins.opnd
        get = {'d': ['ld h,a', 'ld l,b'], 'x': ['push ix', 'pop hl'], 'y': ['push iy', 'pop hl'],
               'u': ['ld h,d', 'ld l,e'], 's': ['ld (xl_sptmp),sp', 'ld hl,(xl_sptmp)']}
        put = {'d': ['ld a,h', 'ld b,l'], 'x': ['push hl', 'pop ix'], 'y': ['push hl', 'pop iy'],
               'u': ['ex de,hl'], 's': ['ld sp,hl']}
        if 'dp' in (a, b):
            if m == 'tfr' and b == 'dp':
                return []
            raise ValueError('dp transfer')
        if 'cc' in (a, b) or 'pc' in (a, b):
            raise ValueError('%s %s,%s' % (m, a, b))
        if m == 'tfr':
            if a in ('a', 'b') and b in ('a', 'b'):
                return ['ld %s,%s' % (b, a)] if a != b else []
            if a in ('a', 'b') or b in ('a', 'b'):
                raise ValueError('8/16 transfer')
            if b == 'u' and a != 'u':
                return get[a] + ['ex de,hl'] if a != 'd' else ['ld d,a', 'ld e,b']
            return get[a] + put[b]
        # exg
        if a in ('a', 'b') and b in ('a', 'b'):
            return ['ld c,a', 'ld a,b', 'ld b,c'] if a != b else []
        regs = {'x': 'ix', 'y': 'iy'}
        if a in regs and b in regs:
            return ['push %s' % regs[a], 'push %s' % regs[b], 'pop %s' % regs[a], 'pop %s' % regs[b]]
        # general: through the stack using HL
        o = get[a] + ['push hl'] + get[b]
        o += put[a] if a != 'u' else ['ex de,hl']
        o += ['pop hl'] + put[b]
        return o

    # --------------------------------------------------------- tile RAM writes
    def is_vram_writer(self, ins):
        return ins.addr in self.vram_writers

    def mark_after(self, ins, op):
        """Mark the tile RAM cell written through op as dirty."""
        mm = re.match(r'^\((i[xy])([+-]\d+)\)$', op)
        if mm and int(mm.group(2)) == 0:
            return ['push %s' % mm.group(1), 'pop hl', 'call xl_mark']
        if mm:
            return ['push af', 'push de', 'push %s' % mm.group(1), 'pop hl', 'ld de,%s' % self.off(int(mm.group(2))),
                    'add hl,de', 'pop de', 'pop af', 'call xl_mark']
        if op == '(hl)':
            return ['call xl_mark']
        if op == '(de)':
            return ['ld h,d', 'ld l,e', 'call xl_mark']
        mm = re.match(r'^\((.*)\)$', op)
        return ['ld hl,%s' % mm.group(1), 'call xl_mark']

    def mark16(self, ins, op):
        s = self.split16(op)
        if s:
            return self.mark_after(ins, s[0]) + self.mark_after(ins, s[1])
        return self.mark_after(ins, op)

    # --------------------------------------------------------- output
    def run(self, outdir, vram_writers):
        self.vram_writers = vram_writers
        self.sorted_addrs = sorted(self.ins)
        self.addr_index = {a: i for i, a in enumerate(self.sorted_addrs)}
        self.liveness()
        os.makedirs(outdir, exist_ok=True)
        chunks = []
        cur = None
        addrs = self.sorted_addrs
        prev_term = True
        for i, a in enumerate(addrs):
            if excluded(a):
                prev_term = True
                cur = None
                continue
            ins = self.ins[a]
            contiguous = i > 0 and addrs[i - 1] + self.ins[addrs[i - 1]].len == a and not excluded(addrs[i - 1])
            if cur is None or not contiguous or prev_term and len(cur['lines']) > 150:
                if cur is not None and not prev_term:
                    cur['lines'].append('        jp %s' % self.label_for(a))
                cur = {'start': a, 'lines': []}
                chunks.append(cur)
            n = self.d.name(a)
            if n:
                cur['lines'].append('%s:' % zname(n))
            if a in self.extra_labels:
                cur['lines'].append('%s:' % self.extra_labels[a])
            mn, opnd = self.d.fmt(ins)
            cur['lines'].append('; %04X  %s %s' % (a, mn, opnd))
            if not skipped(a):
                for l in (OVERRIDE[a] if a in OVERRIDE else self.translate(a)):
                    if l.startswith('.x') or (l.endswith(':') and ' ' not in l):
                        cur['lines'].append(l if l.endswith(':') else l + ':')
                    elif l.startswith(';'):
                        cur['lines'].append('        ' + l)
                    else:
                        cur['lines'].append('        ' + l)
            prev_term = D.is_terminal(ins)
            if not prev_term and (i + 1 == len(addrs) or addrs[i + 1] != a + ins.len or excluded(addrs[i + 1])):
                nxt = a + ins.len
                cur['lines'].append('        jp %s  ; falls into non-code' % self.sym(nxt))
                prev_term = True
        # local labels must not cross chunk boundaries: give every chunk a non-local head label
        for c in chunks:
            first = c['lines'][0]
            c['name'] = first[:-1] if first.endswith(':') else 'xl_chunk_%04X' % c['start']
            if not first.endswith(':'):
                c['lines'].insert(0, c['name'] + ':')
        json.dump([{'name': c['name'], 'start': c['start']} for c in chunks],
                  open(os.path.join(outdir, 'xl_chunks.json'), 'w'), indent=0)
        with open(os.path.join(outdir, 'xl_code.asm'), 'w') as f:
            for c in chunks:
                f.write('; ---- chunk %s (%04X)\n' % (c['name'], c['start']))
                f.write('xl_chunk_%s_begin:\n' % c['name'])
                f.write('\n'.join(c['lines']) + '\n')
                f.write('xl_chunk_%s_end:\n' % c['name'])
        self.write_symbols(outdir)
        self.write_data(outdir)
        return chunks

    def label_for(self, a):
        n = self.d.name(a)
        if n:
            return zname(n)
        if a not in self.extra_labels:
            self.extra_labels[a] = 'xl_L%04X' % a
        return self.extra_labels[a]

    def write_symbols(self, outdir):
        A = self.d.A
        with open(os.path.join(outdir, 'xl_equ.asm'), 'w') as f:
            f.write('; arcade RAM / I/O symbols (identity mapped)\n')
            for v in sorted(A.equ):
                if v >= 0x2800 or True:
                    f.write('%-24s equ %s\n' % (zname(A.equ[v]), hx(v)))
            names = set(A.equ.values())
            for n in range(24):
                if 'slot%d' % n not in names:
                    f.write('%-24s equ %s\n' % ('slot%d' % n, hx(0x3100 + 32 * n)))
            # labels of excluded code that are referenced as data/immediates
            for a in sorted(self.ins):
                if excluded(a) and self.d.name(a):
                    f.write('%-24s equ xl_stub\n' % zname(self.d.name(a)))

    def write_data(self, outdir):
        """Convert the data lines of the 6809 listing to sjasm, at fixed addresses."""
        src = self.d.listing
        out = []
        cur_addr = None
        for line in src:
            m = re.match(r'^([A-Za-z_]\w*):$', line)
            if m:
                pend_label = m.group(1)
                out.append(('label', pend_label))
                continue
            mm = re.match(r'^\s+(fcb|fdb|fcc|fill)\s+(.*?)\s*(;.*)?$', line)
            if not mm:
                if re.match(r'^\s+[a-z]+\b.*;\s*[0-9A-F]{4}  ', line):
                    out.append(('code',))       # instruction: labels before it are code labels
                continue
            kind, args, cm = mm.group(1), mm.group(2), mm.group(3) or ''
            am = re.search(r';\s*([0-9A-F]{4})', cm)
            out.append(('data', kind, args, int(am.group(1), 16) if am else None, cm))
        # assign addresses (data lines carry their address in the comment; fcc
        # lines and pointer continuations may not) and split into the three
        # address windows: $6000-$7FFF page 1 bank, $8000-$BFFF page 2 bank,
        # $C000-$FFFF page 3 RAM image
        items = []           # (addr, labels, [byte exprs], comment)
        pc = None
        pend = []
        for item in out:
            if item[0] == 'label':
                pend.append(item[1])
                continue
            if item[0] == 'code':
                pend = []
                pc = None
                continue
            kind, args, addr, cm = item[1], item[2], item[3], item[4]
            if addr is None:
                addr = pc
            bs = self.data_bytes(kind, args)
            if addr is None:
                pend = []
                continue
            bs = list(bs)
            for i in range(len(bs)):
                for pa, pv in DATA_PATCH.items():
                    if pa <= addr + i < pa + len(pv):
                        bs[i] = pv[addr + i - pa]
            items.append((addr, pend, bs, cm))
            pend = []
            pc = addr + len(bs)
        lines = []
        bucket_of = lambda v: 1 if v < 0x8000 else (2 if v < 0xC000 else 3)
        pcs = {}
        for addr, labels, bs, cm in items:
            if any(s0 <= addr < e0 for s0, e0 in DATA_DROP):
                for l in labels:
                    self.dropped_labels.append((l, addr))
                continue
            first = True
            i = 0
            while i < len(bs):
                a = addr + i
                b = bucket_of(a)
                limit = {1: 0x8000, 2: 0xC000, 3: 0x10000}[b]
                n = min(len(bs) - i, limit - a)
                if pcs.get('cur') != (b, a):
                    lines.append((b, '        org %s' % hx(a)))
                if first:
                    for l in labels:
                        lines.append((b, '%s:' % zname(l)))
                        self.data_labels.append((zname(l), addr))
                lines.append((b, '        db ' + ','.join(bs[i:i + n]) + (('   ' + cm) if first and cm else '')))
                first = False
                i += n
                pcs['cur'] = (b, a + n)
        buckets = {1: [], 2: [], 3: []}
        for b, l in lines:
            buckets[b].append(l)
        for k, v in buckets.items():
            with open(os.path.join(outdir, 'xl_data_p%d.asm' % k), 'w') as f:
                f.write('; arcade data at its original addresses (big-endian words)\n')
                f.write('\n'.join(v) + '\n')
        with open(os.path.join(outdir, 'xl_dataequ.asm'), 'w') as f:
            f.write('; data labels as equates (used to measure the code chunks)\n')
            for n, a in self.data_labels:
                f.write('%-24s equ %s\n' % (n, hx(a)))
        with open(os.path.join(outdir, 'xl_equ.asm'), 'a') as f:
            f.write('; labels of data that is not kept in the port (identity addresses)\n')
            for n, a in self.dropped_labels:
                f.write('%-24s equ %s\n' % (zname(n), hx(a)))
            f.write('; labels inside multi-byte data items\n')
            for line in self.d.listing:
                mm = re.match(r'^([A-Za-z_]\w*)\s+equ\s+\$([0-9A-F]+)\s*$', line)
                if mm and int(mm.group(2), 16) >= 0x6000:
                    f.write('%-24s equ %s\n' % (zname(mm.group(1)), hx(int(mm.group(2), 16))))

    def data_bytes(self, kind, args):
        if kind == 'fcb':
            return [self.zexpr(x) for x in self.split_args(args)]
        if kind == 'fdb':
            out = []
            for x in self.split_args(args):
                z = self.zexpr(x)
                out += ['(%s)>>8' % z, '(%s)&255' % z]
            return out
        if kind == 'fcc':
            return ['%d' % ord(ch) for ch in args[1:-1]]
        if kind == 'fill':
            v, n = args.split(',')
            return [self.zexpr(v.strip())] * int(n)
        return []

    def data_size(self, kind, args):
        if kind == 'fcb':
            return len(self.split_args(args))
        if kind == 'fdb':
            return 2 * len(self.split_args(args))
        if kind == 'fcc':
            return len(args) - 2
        if kind == 'fill':
            return int(args.split(',')[1])
        return 0

    def split_args(self, s):
        return [x.strip() for x in s.split(',')]

    def zexpr(self, e):
        out = []
        for tok in re.split(r'(\$[0-9A-Fa-f]+)', e):
            if tok.startswith('$'):
                out.append('0%sh' % tok[1:].upper())
            else:
                out.append(re.sub(r'[A-Za-z_]\w*', lambda m: zname(m.group(0)), tok))
        return ''.join(out)

    def data_line(self, kind, args):
        if kind == 'fcb':
            return 'db ' + ','.join(self.zexpr(x) for x in self.split_args(args))
        if kind == 'fdb':
            parts = []
            for x in self.split_args(args):
                z = self.zexpr(x)
                parts.append('(%s)>>8,(%s)&255' % (z, z))
            return 'db ' + ','.join(parts)
        if kind == 'fcc':
            return 'db ' + args
        if kind == 'fill':
            v, n = args.split(',')
            return 'ds %s,%s' % (n.strip(), self.zexpr(v.strip()))

def main():
    rom = open(sys.argv[1], 'rb').read()
    cov = json.load(open(sys.argv[2]))
    ann = D.Ann()
    for fpath in sorted(glob.glob(os.path.join(sys.argv[3], '*.ann'))):
        D.parse_ann(fpath, ann)
    d = D.Dis(rom, cov, ann)
    d.run()
    d.collect_refs()
    drp = os.path.join(os.path.dirname(sys.argv[2]), 'datareads.json')
    d.build_xrefs(json.load(open(drp)) if os.path.exists(drp) else {})
    outdir = sys.argv[4]
    tmp = os.path.join(outdir, 'xl_6809.asm')
    os.makedirs(outdir, exist_ok=True)
    d.emit(tmp)
    d.listing = open(tmp).read().split('\n')
    # tile RAM writers: PCs recorded by a MAME Lua script are the address
    # after the writing instruction
    vw = set()
    end_to_start = {a + i.len: a for a, i in d.ins.items()}
    twdir = os.path.join(os.path.dirname(os.path.dirname(sys.argv[2])), 'tw')
    for p in glob.glob(os.path.join(twdir, '*.txt')):
        for line in open(p):
            pc = int(line.split()[0], 16)
            if pc in end_to_start:
                vw.add(end_to_start[pc])
    # plus every store with a $FC00 (-$400) offset or into VIDEORAM/COLORRAM constants
    for a, ins in d.ins.items():
        if ins.mn.startswith('st') or ins.mn.startswith('clr') or ins.mn in ('inc', 'dec', 'com', 'neg'):
            if ins.mode == 'idx' and ins.idx[0] == 'off16':
                vw.add(a)
            if ins.mode == 'ext' and 0x3800 <= ins.opnd < 0x4000:
                vw.add(a)
    x = Xlat(d)
    chunks = x.run(outdir, vw)
    print('chunks %d, tile writers %d, warnings %d' % (len(chunks), len(vw), len(x.warn)))
    with open(os.path.join(outdir, 'xl_warnings.txt'), 'w') as f:
        f.write('\n'.join(x.warn) + '\n')

if __name__ == '__main__':
    main()
