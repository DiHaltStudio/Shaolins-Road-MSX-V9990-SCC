#!/usr/bin/env python3
"""Build the MSX1 + V9990 ROM of the port.

usage: build_port.py   (run from the repository root; needs the arcade data in $ARCADE,
                       default ./arcade: see the README)

1. translate the arcade program (tools/xlat6809.py) -> build/port/xl_*.asm
2. measure every translated code chunk (one sjasm pass with all chunks at 0)
3. place the chunks in the free space of the four CPU pages:
     page 0  RAM  $0000-$27FF  runtime + chunks      (ROM bank 2, copied at boot)
     page 1  ROM  $4000-$7FFF  boot + arcade data $6000-$7FFF + chunks (bank 0)
     page 2  ROM  $8000-$BFFF  arcade data + chunks                     (bank 1)
     page 3  RAM  $C000-$FFEF  arcade data + chunks  (ROM bank 3, copied at boot)
   The arcade data keeps its original addresses; chunks go around it.
4. write build/port/main.asm and assemble build/port/shaolins_v9990.rom
   (Konami SCC mapper, 64 banks of 16 KiB = 128 of 8 KiB: 0-3 program, 4-14 plane B patterns, 15-16 plane A
   patterns, 17-40 sprite atlas, 41-48 raw sprite atlas, 49- sound streams, then the intro pictures)
"""
import os, re, sys, json, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# the arcade project (ROMs, disassembly, analysis, decoded graphics, sound captures)
ARC = os.path.abspath(os.environ.get('ARCADE', os.path.join(ROOT, 'arcade')))
B = os.path.join(ROOT, 'build', 'port')
SRC = os.path.join(ROOT, 'src')

PATB_BANK, PATA_BANK, SPR_BANK, SPRRAW_BANK, SND_BANK = 4, 15, 17, 41, 49
RUNTIME_END = 0x1860        # chunks may use page 0 from here (runtime + sound player ~6 KiB)
PAGE0_END = 0x1C00          # boot stack above, then runtime tables at $2000
BOOT_END = 0x4600            # boot code size reserved at the start of bank 0 (boot + intro)
RESERVED = [(0xE600, 0xF500)]   # page 3: sprite cache map (spr_map), attr_tab, xcache, xr_lut

RUNTIME_SYMS = ['io_palbank', 'io_scroll', 'io_system', 'io_p1', 'io_p2', 'io_dsw1', 'io_dsw2',
                'io_dsw3', 'io_vpos', 'xl_sptmp', 'xl_stub', 'xl_untranslated', 'xl_jphl',
                'xl_jpix', 'xl_jpiy', 'xl_tsthl', 'xl_tstd', 'xl_mul', 'xl_mark']

def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0 or 'rror' in r.stdout:
        print(r.stdout[-3000:], r.stderr[-2000:])
        sys.exit('command failed: %s' % ' '.join(cmd))
    return r

def read_sym(path):
    sy = {}
    for line in open(path):
        m = re.match(r'^(\S+): equ ([0-9A-F]+)h', line)
        if m:
            sy[m.group(1)] = int(m.group(2), 16)
    return sy

def data_occupancy(path):
    """Byte ranges written by an xl_data_p*.asm file."""
    occ = []
    pc = None
    for line in open(path):
        m = re.match(r'^\s+org (0[0-9A-F]+)h', line)
        if m:
            pc = int(m.group(1), 16)
            continue
        m = re.match(r'^\s+db (.*?)(\s+;.*)?$', line)
        if m and pc is not None:
            n = len(split_db(m.group(1)))
            occ.append((pc, pc + n))
            pc += n
    return occ

def split_db(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur); cur = ''
        else:
            cur += ch
    out.append(cur)
    return out

def holes(start, end, used):
    used = sorted(u for u in used if u[1] > start and u[0] < end)
    out, p = [], start
    for s, e in used:
        if s > p:
            out.append([p, s])
        p = max(p, e)
    if p < end:
        out.append([p, end])
    return out

def main():
    os.chdir(ROOT)
    ab = os.path.join(ARC, 'build')
    run(['python3', 'tools/xlat6809.py', os.path.join(ab, 'maincpu_6000.bin'), os.path.join(ab, 'cov', 'coverage.json'),
         os.path.join(ARC, 'disasm', 'ann'), B])
    run(['python3', 'tools/sound_pack.py', os.path.join(ab, 'sound'), os.path.join(B, 'assets')])
    run(['python3', 'tools/intro_assets.py', os.path.join(B, 'assets')])
    run(['python3', 'tools/port_assets.py', os.path.join(ab, 'gfx'), os.path.join(ab, 'vramstats', 'vram_stats.json'),
         os.path.join(B, 'assets')])
    code = open(os.path.join(B, 'xl_code.asm')).read()
    bad = re.findall(r'call xl_untranslated  ; (.*)', code)
    if bad:
        sys.exit('untranslated instructions:\n  ' + '\n  '.join(bad))
    chunks = re.split(r'(?m)^; ---- chunk ', code)[1:]
    chunk_text = {}
    order = []
    for c in chunks:
        name = c.split(' ', 1)[0]
        chunk_text[name] = '; ---- chunk ' + c
        order.append(name)
    # ---- measure
    with open(os.path.join(B, 'measure.asm'), 'w') as f:
        f.write(' include "xl_equ.asm"\n include "xl_dataequ.asm"\n')
        rt = open(os.path.join(SRC, 'runtime.asm')).read()
        syms = set(RUNTIME_SYMS) | set(re.findall(r'(?m)^(xl_\w+|io_\w+):', rt)) | \
            set(re.findall(r'(?m)^(xl_\w+|io_\w+)\s+equ', rt))
        for s in sorted(syms):
            f.write('%s equ 0\n' % s)
        f.write(' defpage 0,0,10000h\n page 0\n org 0\n')
        for n in order:
            f.write(chunk_text[n])
    run(['sjasm', '-s', 'measure.asm', 'measure.bin'], cwd=B)
    sy = read_sym(os.path.join(B, 'measure.sym'))
    size = {n: sy['xl_chunk_%s_end' % n] - sy['xl_chunk_%s_begin' % n] for n in order}
    total = sum(size.values())
    # ---- free space
    occ1 = data_occupancy(os.path.join(B, 'xl_data_p1.asm'))
    occ2 = data_occupancy(os.path.join(B, 'xl_data_p2.asm'))
    occ3 = data_occupancy(os.path.join(B, 'xl_data_p3.asm'))
    H = {0: holes(RUNTIME_END, PAGE0_END, []),
         1: holes(BOOT_END, 0x8000, occ1),
         2: holes(0x8000, 0xC000, occ2),
         3: holes(0xC000, 0xFFF0, occ3 + RESERVED)}
    free = sum(e - s for w in H.values() for s, e in w)
    print('code %d bytes in %d chunks, free %d bytes' % (total, len(order), free))
    place = {}
    for n in sorted(order, key=lambda n: -size[n]):
        need = size[n] + 1
        best = None
        for w in (1, 2, 3, 0):
            for h in H[w]:
                if h[1] - h[0] >= need and (best is None or h[1] - h[0] < best[1][1] - best[1][0]):
                    best = (w, h)
        if best is None:
            sys.exit('no room for chunk %s (%d bytes); free holes: %s' % (n, size[n],
                     sorted(h[1] - h[0] for w in H.values() for h in w)[-10:]))
        w, h = best
        place[n] = (w, h[0])
        h[0] += size[n]
    # ---- main.asm
    by_page = {0: [], 1: [], 2: [], 3: []}
    for n, (w, a) in place.items():
        by_page[w].append((a, n))
    out = ['; generated by tools/build_port.py: do not edit',
           'SCC_SKIP_OWN equ %d' % int(os.environ.get('SCC_SKIP_OWN', '0')),
           ' include "xl_equ.asm"',
           'PATB_BANK equ %d' % PATB_BANK, 'PATA_BANK equ %d' % PATA_BANK, 'SPR_BANK equ %d' % SPR_BANK,
           'SPRRAW_BANK equ %d' % SPRRAW_BANK, 'SND_BANK equ %d' % SND_BANK,
           'INTRO_BANK equ %d' % (SND_BANK + os.path.getsize(os.path.join(B, 'assets', 'sound.bin')) // 16384)]
    for p in range(64):
        org = {0: 0x4000, 1: 0x8000, 2: 0x0000, 3: 0xC000}.get(p, 0x4000)
        out.append(' defpage %d,0%04Xh,04000h' % (p, org))
    def data_blocks(path):
        """Split an xl_data file into (address, text) blocks at its org lines."""
        blocks, cur, addr = [], [], None
        for line in open(path):
            m = re.match(r'^\s+org (0[0-9A-F]+)h', line)
            if m:
                if cur and addr is not None:
                    blocks.append((addr, ''.join(cur)))
                addr, cur = int(m.group(1), 16), []
                continue
            if addr is not None:
                cur.append(line)
        if cur and addr is not None:
            blocks.append((addr, ''.join(cur)))
        return blocks

    def emit_page(segments, base):
        """Segments sorted by address, gaps padded (sjasm's org does not pad)."""
        res = []
        for addr, text in sorted(segments, key=lambda x: x[0]):
            res.append(' ds 0%04Xh-$,0' % addr if addr != base else '')
            res.append(text)
        return res

    out.append(' page 0')
    out.append(' org 04000h')
    out.append(' include "%s/boot.asm"' % SRC)
    out.append('boot_end:')
    segs = data_blocks(os.path.join(B, 'xl_data_p1.asm')) + [(a, chunk_text[n]) for a, n in by_page[1]]
    out += emit_page(segs, 0x4000)
    out.append(' page 1')
    out.append(' org 08000h')
    segs = data_blocks(os.path.join(B, 'xl_data_p2.asm')) + [(a, chunk_text[n]) for a, n in by_page[2]]
    out += emit_page(segs, 0x8000)
    out.append(' page 2')
    out.append(' org 00000h')
    out.append(' include "%s/runtime.asm"' % SRC)
    out.append('rt_end:')
    out += emit_page([(a, chunk_text[n]) for a, n in by_page[0]], 0x0000)
    out.append(' page 3')
    out.append(' org 0C000h')
    segs = data_blocks(os.path.join(B, 'xl_data_p3.asm')) + [(a, chunk_text[n]) for a, n in by_page[3]]
    out += emit_page(segs, 0xC000)
    asset = os.path.join(B, 'assets')
    for i in range(11):
        out += [' page %d' % (PATB_BANK + i), ' incbin "%s/planeB.bin",%d,16384' % (asset, i * 16384)]
    for i in range(2):
        out += [' page %d' % (PATA_BANK + i), ' incbin "%s/planeA.bin",%d,16384' % (asset, i * 16384)]
    for i in range(24):
        out += [' page %d' % (SPR_BANK + i), ' incbin "%s/sprites.bin",%d,16384' % (asset, i * 16384)]
    for i in range(8):
        out += [' page %d' % (SPRRAW_BANK + i), ' incbin "%s/sprites_raw.bin",%d,16384' % (asset, i * 16384)]
    nsnd = os.path.getsize(os.path.join(asset, 'sound.bin')) // 16384
    for i in range(nsnd):
        out += [' page %d' % (SND_BANK + i), ' incbin "%s/sound.bin",%d,16384' % (asset, i * 16384)]
    nintro = os.path.getsize(os.path.join(asset, 'intro.bin')) // 16384
    if SND_BANK + nsnd + nintro > 64:
        sys.exit('ROM full: sound and intro need banks %d-%d' % (SND_BANK, SND_BANK + nsnd + nintro - 1))
    for i in range(nintro):
        out += [' page %d' % (SND_BANK + nsnd + i), ' incbin "%s/intro.bin",%d,16384' % (asset, i * 16384)]
    for p in range(SND_BANK + nsnd + nintro, 64):
        out += [' page %d' % p, ' ds 16384,0FFh']
    open(os.path.join(B, 'main.asm'), 'w').write('\n'.join(out) + '\n')
    run(['sjasm', '-s', 'main.asm', 'shaolins_v9990.rom'], cwd=B)
    sy = read_sym(os.path.join(B, 'shaolins_v9990.sym'))
    # ---- checks
    errors = []
    if sy['boot_end'] > BOOT_END:
        errors.append('boot code ends at %04X > %04X' % (sy['boot_end'], BOOT_END))
    if sy['rt_end'] > RUNTIME_END:
        errors.append('runtime ends at %04X > %04X' % (sy['rt_end'], RUNTIME_END))
    for n, (w, a) in place.items():
        b, e = sy['xl_chunk_%s_begin' % n], sy['xl_chunk_%s_end' % n]
        if b != a or e - b != size[n]:
            errors.append('chunk %s placed at %04X size %d, assembled at %04X-%04X' % (n, a, size[n], b, e))
    rom = os.path.join(B, 'shaolins_v9990.rom')
    data = open(rom, 'rb').read()
    lst = open(os.path.join(B, 'shaolins_v9990.lst'), errors='replace').read()
    m = re.search(r'03:F?([0-9A-F]{4})  ((?:[0-9A-F]{2} )+)', lst[lst.find('init_game:'):])
    print('ROM %s: %d bytes; boot ends %04X, runtime ends %04X' % (rom, os.path.getsize(rom), sy['boot_end'], sy['rt_end']))
    for w in range(4):
        used = sum(size[n] for n, (ww, a) in place.items() if ww == w)
        print('  page %d: %d chunks, %d bytes of code' % (w, len(by_page[w]), used))
    if errors:
        print('\n'.join(errors))
        sys.exit(1)
    json.dump({n: {'page': w, 'addr': a, 'size': size[n]} for n, (w, a) in place.items()},
              open(os.path.join(B, 'placement.json'), 'w'), indent=0)

if __name__ == '__main__':
    main()
