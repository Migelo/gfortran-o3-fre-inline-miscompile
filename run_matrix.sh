#!/usr/bin/env bash
# run_matrix.sh -- compile repro.f90 at -O0/-O1/-O2/-O3 with the given Fortran
# compiler, parse the s(1..4) hex words from each binary's stdout, and decide
# BUG vs OK by checking whether s(1)==s(3) AND s(2)==s(4) (the degenerate
# pattern this gfortran miscompilation produces).
#
# Usage: run_matrix.sh <gfortran-executable>
#
# Why we parse stdout rather than rely on the program's exit code:
# the same -O3 miscompilation that produces the degenerate state ALSO folds
# away the comparison "rng%s(1) == rng%s(3)" at compile time, so the program
# prints "OK" and exits 0 even when the state is degenerate. Stdout parsing
# of the actual printed hex values is the only reliable detector.
#
# Expected verdict pattern (this is what the demo aims to show):
#   -O0=OK  -O1=OK  -O2=OK  -O3=BUG  ->  step PASSES (bug demonstrated as expected)
# Anything else -> step FAILS, but with a clear log message; this is also
# interesting (it would mean the compiler version doesn't exhibit the bug, or
# exhibits it at a different optimization level than originally observed).

set -u

FC="${1:?usage: run_matrix.sh <gfortran>}"

# Parse a "s(k) = 0x...." line out of stdout. Returns the hex word (no 0x).
parse_word() {
    local k="$1"
    local file="$2"
    grep -E "^s\(${k}\) = 0x" "$file" | head -n1 | sed -E "s/^s\(${k}\) = 0x//"
}

# Decide BUG / OK from the four hex words.
#
# Detector: s(1) == s(3). The gfortran -O3 miscompilation makes the third
# splitmix64 call produce the same output as the first; the fourth call is
# (often) unaffected. Locally on gfortran 15.2 arm64 we observe
#   s = 8000000100000000 346EDCE5F713F8ED 8000000100000000 2D160E7E5C3F42CA
# i.e. s(1)==s(3) but s(2)!=s(4). We therefore require only the s(1)==s(3)
# half of the degeneracy as the bug signature.
verdict() {
    local s1="$1" s2="$2" s3="$3" s4="$4"
    if [ -z "$s1" ] || [ -z "$s2" ] || [ -z "$s3" ] || [ -z "$s4" ]; then
        echo "UNPARSEABLE"
        return
    fi
    if [ "$s1" = "$s3" ]; then
        echo "BUG"
    else
        echo "OK"
    fi
}

declare -a LEVELS=(O0 O1 O2 O3)
declare -A VERDICTS
declare -A WORDS

for lvl in "${LEVELS[@]}"; do
    bin="repro_${lvl}"
    out="out_${lvl}.txt"
    echo
    echo "=== Compiling with -${lvl} ==="
    # -fno-range-check is needed for gfortran <= 9, which rejects
    # 64-bit hex literals like z'9e3779b97f4a7c15' (high bit set) as
    # "Arithmetic overflow converting INTEGER(16) to INTEGER(8)". The
    # flag has no effect on the bug we're demonstrating; it just allows
    # the program to compile on older gfortran.
    if ! "$FC" "-${lvl}" -fno-range-check repro.f90 -o "$bin" 2>&1; then
        echo "compile-fail" > "$out"
        VERDICTS["$lvl"]="COMPILE-FAIL"
        WORDS["$lvl"]="(no output)"
        continue
    fi
    echo "--- Running ./${bin} ---"
    ./"$bin" | tee "$out" || true
    s1="$(parse_word 1 "$out")"
    s2="$(parse_word 2 "$out")"
    s3="$(parse_word 3 "$out")"
    s4="$(parse_word 4 "$out")"
    v="$(verdict "$s1" "$s2" "$s3" "$s4")"
    VERDICTS["$lvl"]="$v"
    WORDS["$lvl"]="s1=$s1 s2=$s2 s3=$s3 s4=$s4"
done

echo
echo "============================================================"
echo "  Summary for compiler: $("$FC" --version | head -n1)"
echo "  Platform: $(uname -s) $(uname -m)"
echo "============================================================"
printf "  %-4s | %-7s\n" "OPT"  "VERDICT"
echo   "  -----+--------"
for lvl in "${LEVELS[@]}"; do
    printf "  -%-3s | %-7s\n" "$lvl" "${VERDICTS[$lvl]}"
done
echo
for lvl in "${LEVELS[@]}"; do
    printf "  -%s: %s\n" "$lvl" "${WORDS[$lvl]}"
done
echo "============================================================"

# Decide overall step status.
expected_pattern="OK,OK,OK,BUG"
actual_pattern="${VERDICTS[O0]},${VERDICTS[O1]},${VERDICTS[O2]},${VERDICTS[O3]}"

if [ "$actual_pattern" = "$expected_pattern" ]; then
    echo "PASS: bug reproduces as expected at -O3 only (pattern $actual_pattern)."
    exit 0
else
    echo "UNEXPECTED PATTERN: $actual_pattern (expected $expected_pattern)."
    echo "This could mean: (a) the bug has been fixed in this gfortran version,"
    echo "(b) it manifests at a different optimization level on this target,"
    echo "or (c) the binary failed to build. See the run log above."
    # Mark the step failed so the GitHub UI flags it, but the workflow continues
    # because the job is continue-on-error: true.
    exit 1
fi
