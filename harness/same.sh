# same.sh — "the same" with a tolerance, for the scripts that compare the
# builds. Source it after out.sh.
#
#   same A B            text files: every number within TOL relative of its
#                       twin, everything else equal; prints the first line
#                       that is not. (cmp first: bit-exact is the common case.)
#   same_bin A B        binary files: wdiff, every float32 within TOL.
#
# TOL is the caller's (default 1e-9); FTOL, when set, is the fixture's own.
# WDIFF names the wdiff binary.

TOL=${TOL:-1e-9}
WDIFF=${WDIFF:-build/wdiff}

same() {
    paste -d'|' "$1" "$2" | awk -F'|' -v tol="${FTOL:-$TOL}" '
        { n = split($1, a, " "); m = split($2, b, " ")
          if (n != m) { print "line " NR ": " $1 " | " $2; exit 1 }
          for (i = 1; i <= n; i++) {
              if (a[i] == b[i]) continue
              x = a[i] + 0; y = b[i] + 0
              d = x - y; if (d < 0) d = -d
              s = x < 0 ? -x : x; t = y < 0 ? -y : y; if (t > s) s = t
              if (s == 0 || d / s > tol) { print "line " NR " field " i ": " a[i] " vs " b[i]; exit 1 }
          }
        }'
}

same_bin() {
    "$WDIFF" "$1" "$2" "${FTOL:-$TOL}"
}
