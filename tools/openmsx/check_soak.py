#!/usr/bin/env python3
"""Check soak.log files (tools/openmsx/soak.tcl): exit status 1 if a run failed.

usage: check_soak.py SOAKDIR...

A run fails when its log is short (openMSX stopped early), when the frame counter
stops once the game runs (a crash or a hang: the first seconds are the intro, with
no frame counter yet), when the PC sits in xl_untranslated, or when the arcade
state is out of range (stage > 4, loop > 3, lives > 30: memory overwritten).
With SOAK_FAST the soak gives lives and kills enemies, so lives up to 30 are fine.
"""
import os, re, sys

def check(d, symfile):
    log = os.path.join(d, 'soak.log')
    if not os.path.exists(log):
        return 'no log'
    stuck_pc = None
    if symfile and os.path.exists(symfile):
        for l in open(symfile):
            m = re.match(r'^xl_untranslated: equ ([0-9A-F]+)h', l)
            if m:
                stuck_pc = int(m.group(1), 16)
    rows = []
    for l in open(log):
        f = dict(kv.split('=', 1) for kv in l.split() if '=' in kv)
        rows.append(f)
    want = int(os.environ.get('SOAK_EXPECT', '0'))
    if want and len(rows) < want:
        return 'log stops at %d s of %d' % (len(rows), want)
    frozen = 0
    prev = None
    started = False
    ready = False           # the boot message and the intro come first: RAM is not initialised yet
    for f in rows:
        ok_state = int(f['mode']) <= 3 and int(f['stage']) <= 4 and int(f['loop']) <= 3 and int(f['lives']) <= 30
        if not ready:
            if not ok_state or int(f['frame']) == 0:
                continue
            ready = True
        if f.get('mode') != '0':
            started = True
        if started and prev is not None and f['frame'] == prev:
            frozen += 1
            if frozen >= 3:
                return 'frame counter frozen at t=%s (pc %s)' % (f['t'], f['pc'])
        else:
            frozen = 0
        prev = f['frame']
        pc = int(f['pc'], 16)
        if stuck_pc is not None and stuck_pc <= pc <= stuck_pc + 2:
            return 'untranslated instruction reached at t=%s' % f['t']
        if int(f['stage']) > 4 or int(f['loop']) > 3 or int(f['lives']) > 30:
            return 'state out of range at t=%s: %s' % (f['t'], ' '.join('%s=%s' % kv for kv in f.items()))
    last = rows[-1] if rows else {}
    return 'ok: %d s, last stage %s loop %s score %s' % (len(rows), last.get('stage'), last.get('loop'), last.get('score'))

def main():
    sym = os.environ.get('SOAK_SYM')
    bad = 0
    for d in sys.argv[1:]:
        r = check(d, sym)
        print('%-24s %s' % (os.path.basename(d.rstrip('/')), r))
        if not r.startswith('ok'):
            bad += 1
    print('FAIL' if bad else 'PASS')
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()
