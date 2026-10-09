# Soak test: random play for SOAK_SECS; screenshots every 20 s; forces the
# stage SOAK_STAGE (0-4, optional) by writing the arcade stage variable when a
# game starts; SOAK_FAST gives lives and leaves one enemy per stage; logs
# PC/frame/state every second (checked by check_soak.py).
set throttle off
catch { set mute on }      ;# tests are silent
after time 1 { catch { set videosource GFX9000 } }
set ::f [open $::env(SOAK_OUT) w]
set ::n 0
expr {srand(int($::env(SOAK_SEED)))}
set keys {{8 16} {8 128} {8 32} {8 64} {8 1} {4 4}}
proc press {} {
    global keys
    foreach k $keys { keymatrixup [lindex $k 0] [lindex $k 1] }
    set k [lindex $keys [expr {int(rand()*[llength $keys])}]]
    keymatrixdown [lindex $k 0] [lindex $k 1]
    if {rand() < 0.3} { keymatrixdown 8 1 }
    after time 0.25 press
}
proc start {} { keymatrixdown 0 2; after time 0.2 {keymatrixup 0 2}; after time 15 start }
proc log {} {
    incr ::n
    set ::poke_due 1
    puts $::f "t=$::n pc=[format %04X [reg pc]] frame=[peek 0x240E] mode=[peek 0x2A02] st=[peek 0x2A08] stage=[peek 0x2A79] left=[peek 0x2A87] boss=[peek 0x2A98] loop=[peek 0x2A7A] lives=[peek 0x2A78] score=[format %02X%02X%02X [peek 0x2A82] [peek 0x2A83] [peek 0x2A84]]"
    flush $::f
    if {$::n % 20 == 0} { screenshot -raw [format "%s/soak%03d.png" $::env(SOAK_DIR) $::n] }
    if {[info exists ::env(SOAK_DUMPAT)] && $::n == $::env(SOAK_DUMPAT)} {
        set g [open $::env(SOAK_DIR)/dump.bin w]
        fconfigure $g -translation binary
        puts -nonewline $g [debug read_block memory 0x3800 2048]
        puts -nonewline $g [debug read_block {Sunrise GFX9000 VRAM} 0x7E000 8192]
        puts -nonewline $g [debug read_block memory 0x2C00 1024]
        puts -nonewline $g [debug read_block memory 0x3400 1024]
        puts -nonewline $g [debug read_block memory 0x2000 1024]
        puts -nonewline $g [debug read_block memory 0x2480 32]
        close $g
        screenshot -raw $::env(SOAK_DIR)/dump.png
    }
    if {$::n >= $::env(SOAK_SECS)} { close $::f; exit }
    after time 1 log
}
# The game state is only changed when no game tick is running (at the start of
# the interrupt, game_busy $2415 = 0): a change in the middle of a routine could
# make it run away (damage_bar reads the damage twice).
set ::poke_due 0
proc safe_poke {} {
    set ::poke_due 0
    if {[info exists ::env(SOAK_STAGE)] && [peek 0x2A02] == 2 && [peek 0x2A08] <= 1 && [peek 0x2A79] == 0} { poke 0x2A79 $::env(SOAK_STAGE) }
    if {[info exists ::env(SOAK_FAST)] && [peek 0x2A02] == 2} {
        if {[peek 0x2A87] > 1} { poke 0x2A87 1 }
        poke 0x3101 0
    }
}
debug set_bp 0x0068 {$::poke_due && [peek 0x2415] == 0} safe_poke
after time 9 { start; press; log }
