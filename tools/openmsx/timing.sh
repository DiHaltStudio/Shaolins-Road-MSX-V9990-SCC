#!/bin/sh
# usage: tools/openmsx/timing.sh ROM SYMFILE  -> IRQs, game ticks and present time over 1 s of demo (t=30 s)
ROM=$1; SYM=$2
OUT=${TMPDIR:-/tmp}/port_timing.txt
python3 - "$SYM" "$OUT" > ${TMPDIR:-/tmp}/port_timing.tcl <<'PY'
import re, sys
sy = {}
for l in open(sys.argv[1]):
    m = re.match(r'^(\S+): equ ([0-9A-F]+)h', l)
    if m: sy[m.group(1)] = int(m.group(2), 16)
print('set throttle off')
print('catch { set mute on }')
print('set f [open "%s" w]' % sys.argv[2])
print('set ::on 0')
print('proc t {tag} { if {$::on} { puts $::f "$tag [format %.6f [machine_info time]]" } }')
for tag, name in (('IRQ', 'irq_entry'), ('INPUT', 'read_input'), ('GAME', 'irq_handler')):
    print('debug set_bp 0x%04X {} {t %s}' % (sy[name], tag))
print('after time 30 { set ::on 1 }')
print('after time %d { close $f; exit }' % (30 + int(__import__('os').environ.get('TM_LEN', '1'))))
PY
DISPLAY=${TEST_DISPLAY:-:99} OPENMSX_USER_DATA=$HOME/.cache/openmsx-tests/share timeout 200 ${OPENMSX:-openmsx} -machine ${MACHINE:-Sony_HB-10P} -ext gfx9000 \
    -cart "$ROM" -romtype KonamiSCC -script ${TMPDIR:-/tmp}/port_timing.tcl >/dev/null 2>&1
python3 - "$OUT" <<'PY'
import sys
ev = [l.split() for l in open(sys.argv[1])]
irq = [float(t) for k, t in ev if k == 'IRQ']
game = [float(t) for k, t in ev if k == 'GAME']
ii = [float(t) for k, t in ev if k == 'INPUT']
pres = [b - a for a, b in zip(irq, ii)]
n = float(__import__('os').environ.get('TM_LEN', '1'))
print('per second: IRQs %d  game ticks %d  present ms avg %.2f max %.2f' % (len(irq) / n, len(game) / n, 1000 * sum(pres) / len(pres), 1000 * max(pres)))
PY
