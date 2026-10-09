#!/bin/sh
# usage: tools/openmsx/run_soak.sh ROM OUTDIR SECS SEED [STAGE]   (virtual display :99)
ROM=$1; DIR=$2; SECS=$3; SEED=$4; STAGE=$5
mkdir -p "$DIR"
if [ -n "$STAGE" ]; then export SOAK_STAGE=$STAGE; fi
DISPLAY=${TEST_DISPLAY:-:99} OPENMSX_USER_DATA=$HOME/.cache/openmsx-tests/share SOAK_OUT=$DIR/soak.log SOAK_DIR=$DIR SOAK_SECS=$SECS \
    SOAK_SEED=$SEED timeout 3000 ${OPENMSX:-openmsx} -machine ${MACHINE:-Sony_HB-10P} -ext gfx9000 -cart "$ROM" -romtype KonamiSCC \
    -script "$(dirname "$0")/soak.tcl" >/dev/null 2>&1
tail -3 "$DIR/soak.log"
