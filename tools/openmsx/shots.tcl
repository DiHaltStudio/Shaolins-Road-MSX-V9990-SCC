# Timed screenshots and key presses. Environment:
#   SH_DIR    output directory
#   SH_TIMES  space-separated emulated times for screenshots (seconds)
#   SH_KEYS   space-separated "time:row:mask:duration" key presses (MSX keyboard matrix)
#   SH_END    quit time
set throttle off
catch { set mute on }      ;# tests are silent
after time 1 { catch { set videosource GFX9000 } }
set ::sh_n 0
proc shot {} {
    incr ::sh_n
    screenshot -raw [format "%s/shot%02d.png" $::env(SH_DIR) $::sh_n]
}
foreach t $::env(SH_TIMES) { after time $t shot }
if {[info exists ::env(SH_KEYS)]} {
    foreach k $::env(SH_KEYS) {
        lassign [split $k :] t row mask dur
        after time $t "keymatrixdown $row $mask"
        after time [expr {$t + $dur}] "keymatrixup $row $mask"
    }
}
after time $::env(SH_END) exit
