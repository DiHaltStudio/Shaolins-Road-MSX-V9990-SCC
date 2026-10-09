# Statistical PC profiler: from PR_START for PR_LEN seconds sample the PC every
# PR_STEP seconds of emulated time; write one PC per line to PR_OUT.
set throttle off
catch { set mute on }      ;# tests are silent
set ::pr_f [open $::env(PR_OUT) w]
set ::pr_end [expr {$::env(PR_START) + $::env(PR_LEN)}]
proc pr_sample {} {
    puts $::pr_f [format %04X [reg pc]]
    if {[machine_info time] < $::pr_end} { after time $::env(PR_STEP) pr_sample } else { close $::pr_f; exit }
}
after time $::env(PR_START) pr_sample
