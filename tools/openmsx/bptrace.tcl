# Breakpoint logger. Environment:
#   BT_OUT    log file
#   BT_BPS    space-separated hex addresses ("F200 0000 ...")
#   BT_MAX    hits logged per breakpoint (default 3)
#   BT_SECS   emulated seconds before quitting (default 10)
set throttle off
catch { set mute on }      ;# tests are silent
set ::bt_f [open $::env(BT_OUT) w]
set ::bt_max 3
if {[info exists ::env(BT_MAX)]} { set ::bt_max $::env(BT_MAX) }
set secs 10
if {[info exists ::env(BT_SECS)]} { set secs $::env(BT_SECS) }
proc hx {v} { return [format %04X $v] }
proc bt_hit {a} {
    if {![info exists ::bt_n($a)]} { set ::bt_n($a) 0 }
    incr ::bt_n($a)
    if {$::bt_n($a) > $::bt_max} { return }
    set sp [reg sp]
    set st ""
    for {set i 0} {$i < 8} {incr i} { append st " [hx [peek16 [expr {($sp + 2*$i) & 0xFFFF}]]]" }
    puts $::bt_f "[format %.4f [machine_info time]] BP $a pc=[hx [reg pc]] sp=[hx $sp] af=[hx [reg af]] bc=[hx [reg bc]] de=[hx [reg de]] hl=[hx [reg hl]] ix=[hx [reg ix]] iy=[hx [reg iy]] stack:$st"
    flush $::bt_f
}
foreach a $::env(BT_BPS) { debug set_bp 0x$a {} "bt_hit $a" }
after time 1 { catch { set videosource GFX9000 } }
after time $secs { if {[info exists ::env(BT_SHOT)]} { screenshot -raw $::env(BT_SHOT) }; close $::bt_f; exit }
