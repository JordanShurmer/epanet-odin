# grid.sh — a generated network the real fixtures are too small for. Source
# it, don't run it.
#
#   grid_inp N [HOURS]      an N×N grid of junctions fed from one reservoir
#                           through a pump, with a strip of parallel pipes;
#                           HOURS > 0 runs it that long by the hour with a
#                           daily demand pattern and a decaying chemical
#
# test.sh runs grid_inp 40 (one steady state: the ordering, the fill-in and
# the parallel-link folding have real work to do); audit/prof.sh runs it
# for days, so the step path is measured in its steady state on a network
# with thousands of rows.
grid_inp() {
    awk -v n="$1" -v hours="${2:-0}" 'BEGIN {
        print "[TITLE]\ngrid " n "x" n "\n\n[JUNCTIONS]"
        for (i = 0; i < n; i++) for (j = 0; j < n; j++)
            printf "J%d-%d %d %g\n", i, j, 500 - i - j, 0.3 + ((i * 7 + j * 3) % 5) / 10
        print "\n[RESERVOIRS]\nR1 700\n\n[PIPES]"
        for (i = 0; i < n; i++) for (j = 0; j < n; j++) {
            if (j + 1 < n) printf "H%d-%d J%d-%d J%d-%d 800 8 110 0 Open\n", i, j, i, j, i, j + 1
            if (i + 1 < n) printf "V%d-%d J%d-%d J%d-%d 800 8 110 0 Open\n", i, j, i, j, i + 1, j
        }
        for (j = 0; j + 1 < n; j += 3) printf "P%d J%d-%d J%d-%d 800 6 100 0 Open\n", j, 5, j, 5, j + 1
        print "\n[PUMPS]\nPU1 R1 J0-0 HEAD C1\n\n[CURVES]\nC1 0 150\nC1 3000 100\nC1 6000 30"
        if (hours > 0) {
            print "\n[PATTERNS]\n1 0.5 0.4 0.4 0.5 0.7 0.9 1.2 1.4 1.3 1.2 1.1 1.0\n1 1.0 1.0 1.1 1.2 1.4 1.5 1.3 1.1 0.9 0.8 0.7 0.6"
            print "\n[SOURCES]\nR1 CONCEN 1.0\n\n[REACTIONS]\nGlobal Bulk -0.5\nGlobal Wall -1"
        }
        print "\n[OPTIONS]\nUnits GPM\nHeadloss H-W\nTrials 60\nAccuracy 0.001"
        if (hours > 0) print "Quality Chlorine mg/L\nPattern 1"
        printf "\n[TIMES]\nDuration %d\n", hours
        if (hours > 0) print "Hydraulic Timestep 1:00\nQuality Timestep 0:05\nPattern Timestep 1:00\nReport Timestep 1:00"
        print "\n[END]"
    }'
}
