# out.sh — shared output vocabulary for the scripts. Source it, don't run it.
# (Taken from bywater-mill's scripts/lib/out.sh; keep the two in step.)
#
#   . "$(dirname "$0")/lib/out.sh"
#
# The normal path is SYMBOLS, not prose: a run of ✓ / ✗ on one line, then a
# one-line tally, then — only if something failed — the failure detail with a
# file:line to jump to. A green run is one or two lines total, so a workflow of
# six checks fits on a screen and a real failure is the only thing in it.
#
# Verbosity is one knob, DEBUG (or -v/-vv/-vvv, see debug_flag):
#
#   0  symbols + tally + failures            (default)
#   1  one named line per check
#   2  + the commands and tool output the checks are hiding
#   3  + shell trace (set -x)
#
# Everything here writes to stderr EXCEPT the symbols and the tally, so a
# script's real output can still be piped.

DEBUG=${DEBUG:-0}

# Colour only when a human is looking.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_OK=$(printf '\033[32m') C_BAD=$(printf '\033[31m')
    C_DIM=$(printf '\033[2m') C_OFF=$(printf '\033[0m')
else
    C_OK= C_BAD= C_DIM= C_OFF=
fi

_pass=0
_fail=0
_failures=$(mktemp)
trap 'rm -f "$_failures"' EXIT

# debug_flag ARG — consume a -v/-vv/-vvv/--debug=N argument. Returns 0 if it
# was one (so the caller can shift it away), 1 if it belongs to the script.
debug_flag() {
    case "$1" in
    -v) DEBUG=1 ;;
    -vv) DEBUG=2 ;;
    -vvv) DEBUG=3 ;;
    --debug=*) DEBUG=${1#--debug=} ;;
    *) return 1 ;;
    esac
    [ "$DEBUG" -ge 3 ] && set -x
    return 0
}
[ "${DEBUG:-0}" -ge 3 ] && set -x

# usage [MSG] — print the script's own header comment and exit 1. Not the whole
# header: the title line and the block of invocations under it, then stop. The
# rest of a header is why the script is written the way it is — that is for a
# reader of the file, not for someone who just mistyped a flag.
#
# So a script's usage text is the thing already at the top of it and cannot
# drift from it; the only convention to keep is that the second paragraph of
# the header is how you call it.
usage() {
    [ -n "${1:-}" ] && printf '%serror: %s%s\n' "$C_BAD" "$1" "$C_OFF" >&2
    awk 'NR==1{next} !/^#/{exit}
         {sub(/^# ?/,"")}
         /^[[:space:]]*$/{if (++b==2) exit}
         {print}' "$0" >&2
    exit 1
}

# ok NAME — one passing check.
ok() {
    _pass=$((_pass + 1))
    if [ "$DEBUG" -ge 1 ]; then
        printf '%s✓%s %s\n' "$C_OK" "$C_OFF" "$1"
    else
        printf '%s✓%s' "$C_OK" "$C_OFF"
    fi
}

# bad NAME [DETAIL…] — one failing check. DETAIL is held back and reprinted by
# tally(); a failure you can only see by scrolling is a failure you miss.
bad() {
    _fail=$((_fail + 1))
    name=$1
    shift
    if [ "$DEBUG" -ge 1 ]; then
        printf '%s✗%s %s\n' "$C_BAD" "$C_OFF" "$name"
    else
        printf '%s✗%s' "$C_BAD" "$C_OFF"
    fi
    printf '%s\n' "$name" >>"$_failures"
    for line in "$@"; do
        printf '%s\n' "$line" | sed 's/^/    /' >>"$_failures"
    done
}

# skip NAME — counted as neither.
skip() {
    if [ "$DEBUG" -ge 1 ]; then
        printf '%s· %s%s\n' "$C_DIM" "$1" "$C_OFF"
    else
        printf '%s·%s' "$C_DIM" "$C_OFF"
    fi
}

# note MSG — a line only DEBUG>=1 wants (progress, counts, what was skipped).
note() { [ "$DEBUG" -ge 1 ] && printf '%s%s%s\n' "$C_DIM" "$1" "$C_OFF" >&2; return 0; }

# dbg MSG — a line only DEBUG>=2 wants (commands, raw tool output).
dbg() { [ "$DEBUG" -ge 2 ] && printf '%s%s%s\n' "$C_DIM" "$1" "$C_OFF" >&2; return 0; }

# run CMD… — run a command, hiding its output below DEBUG=2 unless it fails;
# then the command and its output print. Returns its status.
run() {
    if [ "$DEBUG" -ge 2 ]; then
        "$@"
        return
    fi
    local out status=0
    out=$("$@" 2>&1) || status=$?
    if [ "$status" -ne 0 ]; then
        printf '%s✗ %s%s\n%s\n' "$C_BAD" "$*" "$C_OFF" "$out" >&2
    fi
    return "$status"
}

# tally LABEL — close the symbol line, print `LABEL 12✓`, then any failures.
# Exits 1 if anything failed, so a script can end with `tally foo` alone.
tally() {
    [ "$DEBUG" -ge 1 ] || printf '\n'
    if [ "$_fail" -eq 0 ]; then
        printf '%s%s %d✓%s\n' "$C_OK" "$1" "$_pass" "$C_OFF"
    else
        printf '%s%s %d✓ %d✗%s\n' "$C_BAD" "$1" "$_pass" "$_fail" "$C_OFF"
        printf '\n' >&2
        cat "$_failures" >&2
        return 1
    fi
}
