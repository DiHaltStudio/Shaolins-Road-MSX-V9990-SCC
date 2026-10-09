#!/bin/sh
# usage: SH_TIMES="..." [SH_KEYS="..."] tools/openmsx/run_shots.sh ROM OUTDIR ENDSECS  (virtual display :99)
ROM=$1; DIR=$2; END=$3
mkdir -p "$DIR"; rm -f "$DIR"/shot*.png
DISPLAY=${TEST_DISPLAY:-:99} OPENMSX_USER_DATA=$HOME/.cache/openmsx-tests/share SH_DIR=$DIR SH_END=$END timeout 600 ${OPENMSX:-openmsx} \
    -machine ${MACHINE:-Sony_HB-10P} -ext gfx9000 -cart "$ROM" -romtype KonamiSCC -script "$(dirname "$0")/shots.tcl" >/dev/null 2>&1
ls "$DIR"
