#!/bin/sh
# usage: tools/openmsx/test.sh ROM SYMFILE OUTDIR [SECS]
# Automatic test of the port (openMSX on the display $TEST_DISPLAY, default :99,
# muted, unthrottled): soak runs in parallel, then check_soak.py.
#   fast1, fast2   SOAK_FAST (lives and enemies helped): every stage, bosses,
#                  GUTS!, the second loop (bird and rock), game over and ranking
#   play           plain random play: deaths, game over, name entry, attract
# Exit status 1 if a run crashed, hung or overwrote the game state.
ROM=$1; SYM=$2; OUT=$3; SECS=${4:-600}
DIR=$(dirname "$0")
mkdir -p "$OUT"
SOAK_FAST=1 sh "$DIR/run_soak.sh" "$ROM" "$OUT/fast1" "$SECS" 21 >/dev/null &
SOAK_FAST=1 sh "$DIR/run_soak.sh" "$ROM" "$OUT/fast2" "$SECS" 44 >/dev/null &
sh "$DIR/run_soak.sh" "$ROM" "$OUT/play" "$SECS" 9 >/dev/null &
wait
SOAK_SYM="$SYM" SOAK_EXPECT="$SECS" python3 "$DIR/check_soak.py" "$OUT/fast1" "$OUT/fast2" "$OUT/play"
