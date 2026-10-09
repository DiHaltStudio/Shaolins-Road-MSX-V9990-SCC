#!/usr/bin/env python3
"""Map sampled PCs (tools/openmsx/profile.tcl) to the nearest preceding symbol
of the port's sym file and print the hottest symbols.
usage: profile_report.py SAMPLES SYMFILE [N]"""
import sys, re, bisect, collections
pcs = [int(l, 16) for l in open(sys.argv[1]) if l.strip()]
sy = []
for l in open(sys.argv[2]):
    m = re.match(r'^(\S+): equ ([0-9A-F]+)h', l)
    if m and '.' not in m.group(1) and not m.group(1).startswith('xl_chunk_') \
            and not re.match(r'^[A-Z0-9_]+$', m.group(1)) and not m.group(1).startswith(('io_', 'VR_')):
        sy.append((int(m.group(2), 16), m.group(1)))
sy.sort()
addrs = [a for a, n in sy]
c = collections.Counter()
for pc in pcs:
    i = bisect.bisect_right(addrs, pc) - 1
    c[sy[i][1] if i >= 0 else '?'] += 1
n = int(sys.argv[3]) if len(sys.argv) > 3 else 40
for name, k in c.most_common(n):
    print('%5.1f%%  %s' % (100.0 * k / len(pcs), name))
