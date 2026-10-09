#!/usr/bin/env python3
"""Pack the captured arcade sounds into event streams for the port's player.

usage: sound_pack.py SOUND_DIR OUT_DIR
  SOUND_DIR: captures made in MAME of every sound of the sound test (NN_name.txt, list.txt)
  OUT_DIR:   sound.bin (16 KiB banks, index at the start of the first one), sound.txt (report)

The arcade drives two SN76489 (SN#1 1.536 MHz, SN#2 3.072 MHz). Music uses SN#1 tones
0-1 and SN#2 tones 1-2 (voices M0-M3), effects SN#2 tone 0, SN#1 tone 2 and SN#1 noise
(voices E0, E1, N). The register state is sampled once per MSX frame (59.94 Hz) and
every change is written as an event:

  $00            end (voices of the stream silent)
  $01            loop point
  $02            go to the loop point
  $10+v lo hi    voice v period Q (12 bits): PSG period = Q, SCC register = Q - 1
                 (same pitch on both: Q = 1789772.5 * 2 * p / clock of the SN chip)
  $20+n          noise period n (PSG, 0..31)
  $40+16v+a      voice v attenuation a (SN76489 steps of 2 dB, 15 = off)
  $80+n          wait n frames (1..127)

Index (start of the first bank, page 2 address $8000): 24 effects ($00-$17), 16 music
($40-$4F), 16 fast music (stage theme + tempo command): 3 bytes each, [bank, lo, hi],
bank $FF = none.

Seek table (after the index): the game start music ($49) goes on with the stage 1 theme
and cannot be interrupted, so a tempo command speeds it up where it is. The player then
jumps into the fast stage 1 theme at the same place: entries every 32 frames of that
stream [bank, lo, hi, 4 x (Q lo, Q hi, attenuation)], after a header
[count, loop bank, loop lo, loop hi, loop frame lo, loop frame hi].
sound.inc gives the constants the player needs.
"""
import os, sys, re

FRAME = 1.0 / 59.94
CLOCK = (1536000.0, 3072000.0)
PSG = 1789772.5
BANK = 16384
INDEX = (24 + 16 + 16) * 3

# loop points measured on the captures: (start s, length s)
LOOPS = {
    0x49: (27.15, 23.232),   # game start: jingle (0-4.65 s), stage 1 theme from 4.65 s
    0x4A: (22.53, 23.232), 0x4F: (0.0, 21.12), 0x4E: (0.0, 12.67), 0x4C: (0.0, 11.62),
    0x41: (0.0, 10.56), 0x4D: (0.0, 10.56),
}
LOOPS_FAST = {0x4A: (14.37, 14.784), 0x4F: (0.0, 14.78), 0x4E: (0.0, 8.45), 0x4C: (0.0, 7.39),
              0x41: (0.0, 6.34)}

MUSIC_VOICES = ((0, 0), (0, 1), (1, 1), (1, 2))      # (chip, tone)
SFX_VOICES = ((1, 0), (0, 2))

def load(path):
    return [tuple(map(int, l.split())) for l in open(path)]

class Chips:
    def __init__(self):
        self.latch = [0, 0]
        self.per = [[1024] * 3 for _ in range(2)]
        self.att = [[15] * 4 for _ in range(2)]
        self.noise = [0, 0]

    def write(self, c, b):
        if b & 0x80:
            self.latch[c] = (b >> 4) & 7
            r = self.latch[c]
            if r & 1:
                self.att[c][r >> 1] = b & 15
            elif r < 6:
                self.per[c][r >> 1] = (self.per[c][r >> 1] & 0x3F0) | (b & 15)
            else:
                self.noise[c] = b & 7
        else:
            r = self.latch[c]
            if r & 1:
                self.att[c][r >> 1] = b & 15
            elif r < 6:
                self.per[c][r >> 1] = ((b & 0x3F) << 4) | (self.per[c][r >> 1] & 15)

def q_of(c, p):
    p = p or 1024
    return max(1, min(4095, int(round(PSG * 2 * p / CLOCK[c]))))

def noise_np(ch):
    """SN#1 noise -> PSG noise period."""
    r = ch.noise[0] & 3
    if r == 3:
        f = CLOCK[0] / (32.0 * (ch.per[0][2] or 1024))
    else:
        f = CLOCK[0] / (512.0 * (1 << r))
    return max(1, min(31, int(round(PSG / (16.0 * f)))))

def frames(ev, music):
    """state of the stream's voices at every MSX frame."""
    ch = Chips(); out = []; i = 0
    end = ev[-1][0] / 1e6 if ev else 0
    n = int(end / FRAME) + 2
    for k in range(n):
        lim = (k + 1) * FRAME * 1e6
        while i < len(ev) and ev[i][0] < lim:
            ch.write(ev[i][1], ev[i][2]); i += 1
        if music:
            st = [(q_of(c, ch.per[c][t]), ch.att[c][t]) for c, t in MUSIC_VOICES]
            out.append((st, None))
        else:
            st = [(q_of(c, ch.per[c][t]), ch.att[c][t]) for c, t in SFX_VOICES]
            st.append((0, ch.att[0][3]))
            out.append((st, noise_np(ch)))
    return out

KEY = 32

def encode(fr, loop=None, keys=None):
    """event bytes; loop = (start frame, end frame) or None. keys: list filled with
    (offset, frame, state) every KEY frames (the stream is cut there)."""
    out = bytearray()
    prev = [(None, None)] * 4; prevn = None; wait = 0
    stop = loop[1] if loop else len(fr)
    # trailing silence of one-shot sounds is dropped
    if not loop:
        while stop > 1 and all(a == 15 for q, a in fr[stop - 1][0]):
            stop -= 1
        stop += 1
    def flush():
        nonlocal wait
        while wait:
            w = min(wait, 127); out.append(0x80 | w); wait -= w
    for k in range(min(stop, len(fr))):
        if keys is not None and k % KEY == 0:
            flush()
            keys.append((len(out), k, [tuple(x) for x in (fr[k - 1][0] if k else [(1, 15)] * 4)]))
        if loop and k == loop[0]:
            flush(); out.append(0x01)
            if keys is not None:
                keys.append(('loop', len(out), k))
            prev = [(None, None)] * 4; prevn = None      # the loop restarts from a full state
        st, np_ = fr[k]
        ev = bytearray()
        for v, (q, a) in enumerate(st):
            pq, pa = prev[v]
            if a < 15 and q != pq and not (v == 2 and np_ is not None):
                ev += bytes((0x10 + v, q & 255, q >> 8)); pq = q
            if a != pa:
                ev.append(0x40 + 16 * v + a); pa = a
            prev[v] = (pq, pa)
        if np_ is not None and st[2][1] < 15 and np_ != prevn:
            ev.append(0x20 + np_); prevn = np_
        if ev:
            flush(); out += ev
        wait += 1
    flush()
    if loop:
        out.append(0x02)
    else:
        for v in range(len(fr[0][0])):
            out.append(0x40 + 16 * v + 15)
        out.append(0x00)
    return out

def main():
    src, dst = sys.argv[1:3]
    os.makedirs(dst, exist_ok=True)
    names = {}
    for idx, line in enumerate(open(os.path.join(src, 'list.txt')), 1):
        name, bytes_ = line.strip().split('|')
        names[idx] = (name, [int(x, 16) for x in bytes_.split()])
    sfx, music, fast = {}, {}, {}
    report = []
    seek_keys = []
    for idx, (name, cmds) in sorted(names.items()):
        path = os.path.join(src, '%02d_%s.txt' % (idx, name))
        ev = load(path)
        cmds = [c for c in cmds if c != 0]               # leading "stop all"
        m = [c for c in cmds if 0x40 <= c <= 0x4F]
        if m:
            tempo = [c for c in cmds if 0x20 <= c <= 0x3F]
            table = fast if tempo else music
            lp = (LOOPS_FAST if tempo else LOOPS).get(m[0])
            fr = frames(ev, True)
            loop = (int(round(lp[0] / FRAME)), int(round((lp[0] + lp[1]) / FRAME))) if lp else None
            want = tempo and m[0] == 0x4A
            table[m[0] & 15] = encode(fr, loop, seek_keys if want else None)
            report.append('%-24s music $%02X%s %s %5d bytes' % (name, m[0], ' fast' if tempo else '',
                          ('loop %.2f+%.2f s' % lp) if lp else 'one shot', len(table[m[0] & 15])))
        else:
            fr = frames(ev, False)
            sfx[cmds[0]] = encode(fr)
            report.append('%-24s effect $%02X %5d bytes' % (name, cmds[0], len(sfx[cmds[0]])))
    # place the streams in 16 KiB banks (index first)
    streams = [('s', k, v) for k, v in sorted(sfx.items())] + [('m', k, v) for k, v in sorted(music.items())] + \
              [('f', k, v) for k, v in sorted(fast.items())]
    nkeys = len([k for k in seek_keys if k[0] != 'loop'])
    SEEK = INDEX
    banks = [bytearray(INDEX + 6 + 15 * nkeys)]
    where = {}
    for kind, k, data in sorted(streams, key=lambda x: -len(x[2])):
        assert len(data) <= BANK, 'stream too long'
        for b, buf in enumerate(banks):
            if len(buf) + len(data) <= BANK:
                break
        else:
            banks.append(bytearray()); b = len(banks) - 1
        where[(kind, k)] = (b, 0x8000 + len(banks[b]))
        banks[b] += data
    idx = banks[0]
    for i in range(INDEX // 3):
        idx[3 * i] = 0xFF
    for (kind, k), (b, a) in where.items():
        slot = {'s': k, 'm': 24 + k, 'f': 40 + k}[kind]
        idx[3 * slot:3 * slot + 3] = bytes((b, a & 255, a >> 8))
    # seek table of the fast stage 1 theme
    b, a = where[('f', 0x0A)]
    lp = [k for k in seek_keys if k[0] == 'loop'][0]
    tab = bytearray((nkeys, b, (a + lp[1]) & 255, (a + lp[1]) >> 8, lp[2] & 255, lp[2] >> 8))
    for off, frame, st in [k for k in seek_keys if k[0] != 'loop']:
        tab += bytes((b, (a + off) & 255, (a + off) >> 8))
        for q, att in st:
            tab += bytes((q & 255, q >> 8, att))
    idx[SEEK:SEEK + len(tab)] = tab
    jingle = int(round(4.65 / FRAME))
    ratio = int(round(256 * LOOPS_FAST[0x4A][1] / LOOPS[0x4A][1]))
    open(os.path.join(dst, 'sound.inc'), 'w').write(
        '; generated by tools/sound_pack.py\n'
        'SND_SEEK equ 08000h+%d      ; seek table of the fast stage 1 theme\n'
        'SND_JINGLE equ %d           ; frames of the game start jingle before the stage 1 theme\n'
        'SND_RATIO equ %d            ; fast / normal tempo of the stage 1 theme, x256\n'
        'SND_KEY equ %d              ; frames between seek entries\n'
        'SND_NBANKS equ %d\n' % (SEEK, jingle, ratio, KEY, len(banks)))
    blob = b''.join(bytes(x) + bytes(BANK - len(x)) for x in banks)
    open(os.path.join(dst, 'sound.bin'), 'wb').write(blob)
    total = sum(len(x[2]) for x in streams)
    report.append('%d streams, %d bytes, %d banks of 16 KiB' % (len(streams), total, len(banks)))
    open(os.path.join(dst, 'sound.txt'), 'w').write('\n'.join(report) + '\n')
    print(report[-1])

if __name__ == '__main__':
    main()
