/*
 * Minimal C cross-language reproducer for the same gcc -O3 miscompile that
 * repro.f90 demonstrates in gfortran. The C version eliminates the Fortran
 * front end and the contained-subroutine inliner from suspicion: the bug
 * survives in straight-line C with no procedure boundary, no intent(inout)
 * argument, no derived type, and no `contains` block. The shared cause is
 * therefore in the gcc mid-end (EVRP / value-range and overflow reasoning),
 * not in gfortran.
 *
 * Build/run:
 *   gcc -O3 repro_min.c -o m && ./m; echo exit=$?
 *
 * BUG output (gcc 9.5 through 15.2 with default -fstrict-overflow):
 *   s[0] = 0x7FFFFFFFFFFFFFFF
 *   s[1] = 0x8000000000000000
 *   s[2] = 0x7FFFFFFFFFFFFFFF      <-- equal to s[0]
 *
 * On gcc 9.5 / 10.1 / 11.1 the runtime check `if (s[0] == s[2])` catches
 * the miscompile and the program exits 1. On gcc 12.1 and newer the bug
 * has become worse: EVRP folds the same chain to the same point-values
 * (s[0] = s[2] = INT64_MAX in the printf) BUT simultaneously decides that
 * `s[0] != s[2]` must hold, so the BUG branch is removed and the program
 * prints "OK" while clearly displaying identical hex values. Exit code on
 * gcc 12.1..15.2 -O3 is 0 (false-clean). See README.md, "EVRP makes
 * internally inconsistent inferences" for why this matters.
 *
 * CLEAN output (with -fno-strict-overflow, -fwrapv, -O0, or -O1):
 *   s[0] = 0xBFA0DD452DD35E32
 *   s[1] = 0xEA7170CF4875AA79
 *   s[2] = 0x154204596317F6C0
 *
 * What's load-bearing:
 *   * The seed value must arrive at runtime (here via argc). Constant-
 *     folded seeds let gcc evaluate at compile time and bypass the bug.
 *   * The body is two operations: int64 add of an overflowing constant,
 *     then int64 multiply by an overflowing constant.
 *   * Repeat the (add, multiply, store) triple at least 3 times so that
 *     the s[0]==s[2] equality is a non-trivial runtime invariant.
 *   * No subroutine calls are needed in C -- straight-line code triggers
 *     it, unlike the Fortran case where init_rng/splitmix64 had to stay
 *     separate. The mid-end optimisers see the same signed-overflow chain
 *     either way.
 */

#include <stdio.h>
#include <stdint.h>

int main(int argc, char **argv) {
    (void)argv;
    int64_t s[3];
    int64_t sm_state = (int64_t)argc;

    sm_state = sm_state + (int64_t)0x9e3779b97f4a7c15LL;
    s[0] = sm_state * (int64_t)0x94d049bb133111ebLL;

    sm_state = sm_state + (int64_t)0x9e3779b97f4a7c15LL;
    s[1] = sm_state * (int64_t)0x94d049bb133111ebLL;

    sm_state = sm_state + (int64_t)0x9e3779b97f4a7c15LL;
    s[2] = sm_state * (int64_t)0x94d049bb133111ebLL;

    printf("s[0] = 0x%016llX\n", (unsigned long long)s[0]);
    printf("s[1] = 0x%016llX\n", (unsigned long long)s[1]);
    printf("s[2] = 0x%016llX\n", (unsigned long long)s[2]);

    if (s[0] == s[2]) {
        printf("BUG: s[0] == s[2]\n");
        return 1;
    }
    printf("OK: s[0] != s[2]\n");
    return 0;
}
