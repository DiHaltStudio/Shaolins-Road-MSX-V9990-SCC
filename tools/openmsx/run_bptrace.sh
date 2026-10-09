#!/bin/sh
# usage: BT_BPS="F200 0000" tools/openmsx/run_bptrace.sh ROM LOG [SECS]   (virtual display :99)
ROM=$1; LOG=$2; SECS=${3:-10}
DISPLAY=${TEST_DISPLAY:-:99} OPENMSX_USER_DATA=$HOME/.cache/openmsx-tests/share BT_OUT=$LOG BT_SECS=$SECS timeout 300 ${OPENMSX:-openmsx} \
    -machine ${MACHINE:-Sony_HB-10P} -ext gfx9000 -cart "$ROM" -romtype KonamiSCC -script "$(dirname "$0")/bptrace.tcl" >/dev/null 2>&1
cat "$LOG"
