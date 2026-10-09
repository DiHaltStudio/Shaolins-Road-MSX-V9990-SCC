# Screenshots of the game for the manual (docs/img): runs soak.tcl (random play) and saves a
# screenshot the first time each situation is seen. Environment as soak.tcl, plus MSHOT_DIR.
#   title, ranking, play_s0..4 (one per stage), boss, guts, gameover, nameentry
source [file join [file dirname [info script]] soak.tcl]
set ::shot_done [dict create]
set ::stage_ticks [dict create]
proc shot_once {name} {
    if {[dict exists $::shot_done $name]} { return }
    dict set ::shot_done $name 1
    screenshot -raw [file join $::env(MSHOT_DIR) $name.png]
}
proc mshots {} {
    set t [machine_info time]
    set mode [peek 0x2A02]; set st [peek 0x2A08]; set stage [peek 0x2A79]; set loop [peek 0x2A7A]
    if {$mode == 1 && [peek 0x2A05] == 1 && $st == 4 && [peek 0x20A1] == 0} {
        dict incr ::stage_ticks title
        if {[dict get $::stage_ticks title] > 150} { shot_once title }
    }
    if {$mode == 1 && [peek 0x2A05] == 3 && [peek 0x20A1] == 0} {
        dict incr ::stage_ticks ranking
        if {[dict get $::stage_ticks ranking] > 150} { shot_once ranking }
    }
    if {$mode == 2 && $st == 4 && [peek 0x2A98] == 0 && [peek 0x2A87] > 0} {
        dict incr ::stage_ticks "$loop$stage"
        if {[dict get $::stage_ticks "$loop$stage"] > 120} { shot_once play_s$stage }
    }
    if {$mode == 2 && $st == 4 && [peek 0x2A98] != 0 && [peek 0x3101] != 4} {
        dict incr ::stage_ticks boss$stage
        if {[dict get $::stage_ticks boss$stage] > 40} { shot_once boss_s$stage }
    }
    if {$mode == 2 && [peek 0x3031] > 0 && [peek 0x3031] < 0xB8} { shot_once guts }
    if {[peek 0x20A4] == 1} { shot_once gameover }
    if {$mode == 2 && $st == 7 && [peek 0x2A0B] == 3} { shot_once nameentry }
    after time 0.05 mshots
}
after time 10 mshots
