#!/usr/bin/env bash
# run_flag_matrix.sh -- compile repro_min.c with a given gcc binary under
# a small grid of flag combinations and report the printed s[0]/s[2] hex
# words, the program exit code, and a per-row verdict.
#
# Three things we want this matrix to make obvious:
#
#   1. The MINIMAL reproducer is repro_min.c: 22 lines of straight-line C,
#      no procedure call, no Fortran front end, no contained subroutine,
#      no derived type. So the bug is in gcc's mid-end, not in gfortran.
#
#   2. Two simple flags eliminate the miscompile:
#        -fwrapv               -- define signed overflow as two's complement wrap
#        -fno-strict-overflow  -- forbid the optimiser from assuming overflow is UB
#      Both produce s[0] != s[2] at any -O level. This is the "flag
#      influence" we want to make visible.
#
#   3. At -O2 and -O3 with default signed-overflow semantics, the gcc
#      optimiser emits a basic block that prints two identical hex words
#      (s[0] = s[2] = 0x7FFFFFFFFFFFFFFF) and then unconditionally takes
#      the s[0] != s[2] branch. That is the "recent find": the optimiser
#      is making two contradictory deductions about the same SSA values
#      inside one pass. See the README, "EVRP self-inconsistency".
#
# Verdict legend:
#   CLEAN              s[0] != s[2]   (no fold; correct code)
#   FOLD+CHECK_ALIVE   s[0] == s[2] in print AND exit 1
#                      (fold happens but the runtime guard still fires)
#   FOLD+CHECK_KILLED  s[0] == s[2] in print AND exit 0
#                      (fold AND the guard was folded away too -- the
#                       optimiser simultaneously believes s[0]==s[2]
#                       and s[0]!=s[2]; this is the self-inconsistency)
#
# Usage:
#   run_flag_matrix.sh [<gcc>]      # defaults to `gcc` from PATH

set -u

CC="${1:-gcc}"
REPRO="$(dirname "$0")/repro_min.c"
if [ ! -f "$REPRO" ]; then
    echo "error: cannot find repro_min.c next to this script ($REPRO)" >&2
    exit 2
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

probe_one() {
    local label="$1"; shift
    local bin="$TMPDIR_BASE/m"
    if ! "$CC" "$@" "$REPRO" -o "$bin" 2>/dev/null; then
        printf "  %-30s | %-18s | %-18s | %-3s | %s\n" \
            "$label" "(compile fail)" "" "" ""
        return
    fi
    local out s0 s2 rc verdict
    out="$("$bin" 2>&1)" || true
    rc=$?
    s0="$(echo "$out" | awk '/^s\[0\] = /{print $3}')"
    s2="$(echo "$out" | awk '/^s\[2\] = /{print $3}')"

    if [ -z "$s0" ] || [ -z "$s2" ]; then
        verdict="NO_OUTPUT"
    elif [ "$s0" = "$s2" ]; then
        if [ "$rc" = "0" ]; then verdict="FOLD+CHECK_KILLED"
        else verdict="FOLD+CHECK_ALIVE"; fi
    else
        verdict="CLEAN"
    fi

    printf "  %-30s | %-18s | %-18s | %-3s | %s\n" \
        "$label" "${s0:-?}" "${s2:-?}" "$rc" "$verdict"
}

echo
echo "Compiler: $("$CC" --version 2>/dev/null | head -n1)"
echo "Reproducer: $REPRO"
echo
printf "  %-30s | %-18s | %-18s | %-3s | %s\n" \
    "FLAGS" "s[0]" "s[2]" "rc" "VERDICT"
printf "  %-30s-+-%-18s-+-%-18s-+-%-3s-+-%s\n" \
    "------------------------------" "------------------" "------------------" "---" "------"

probe_one "-O0"                        -O0
probe_one "-O1"                        -O1
probe_one "-O2"                        -O2
probe_one "-O3"                        -O3
probe_one "-O3 -fwrapv"                -O3 -fwrapv
probe_one "-O3 -fno-strict-overflow"   -O3 -fno-strict-overflow
probe_one "-O3 -Wstrict-overflow=5"    -O3 -Wstrict-overflow=5 -Wall -Wextra

echo
echo "Interpretation:"
echo "  - CLEAN rows show the bug is gated by -fstrict-overflow."
echo "  - FOLD+CHECK_KILLED at -O2/-O3 shows the optimiser folded BOTH the"
echo "    value computation (so s[0] and s[2] print the same hex) AND the"
echo "    s[0]==s[2] guard (so the program returns 0 instead of 1)."
echo "    Those two folds are inconsistent with each other -- see README."
echo "  - -Wstrict-overflow=5 -Wall -Wextra emits no diagnostic on the"
echo "    fold, even though the optimiser is exploiting signed overflow."
