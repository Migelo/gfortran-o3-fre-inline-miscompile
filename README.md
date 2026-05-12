# gfortran -O3 SplitMix64 surprise — case study, not a gcc bug

[![demonstrate-bug](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions/workflows/demonstrate.yml/badge.svg)](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions/workflows/demonstrate.yml)

> **Retraction note.** This repository was initially set up to file a gcc
> bug report about a SplitMix64 RNG initialiser silently producing
> `s(1) == s(3)` at `-O3` (the original framing the repo URL reflects:
> "gfortran FRE/inliner miscompile"). On closer analysis the cause is
> signed-int64 overflow UB exploitation, which is settled upstream
> policy: see [PR 30475](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=30475),
> RESOLVED INVALID since 2007. There is no gcc defect here to file. The
> repository is preserved as a case study of how subtle this UB pattern
> can be inside a production scientific code, and as documentation of
> the one-line fix.

## TL;DR

A small SplitMix64 step compiled with `gcc`/`gfortran` at `-O2` or
higher and default `-fstrict-overflow` can silently produce a
degenerate RNG state. The cause is the signed-int64 multiplies by
`0x94d049bb133111eb` (high bit set, so the product overflows the signed
range), which is undefined behaviour the optimiser is allowed to
exploit. The fix is one flag — `-fwrapv` or `-fno-strict-overflow` —
applied to the file that does the mixing. Either flag eliminates the
miscompile at every -O level.

The repository contains:

- [`repro_min.c`](repro_min.c) — 22-line minimal C reproducer.
- [`run_flag_matrix.sh`](run_flag_matrix.sh) — a small flag grid
  showing precisely which options change the verdict.
- [`repro.f90`](repro.f90) — the original Fortran reproducer extracted
  from the `dHybridR` plasma simulation; this is the production case
  that exposed the issue.
- [`run_matrix.sh`](run_matrix.sh) + a GitHub Actions workflow that
  runs the Fortran reproducer across gfortran 9..15 on Ubuntu and
  macOS, plus Intel `ifx` and NVIDIA `nvfortran` as cross-compiler
  controls.

## Minimal C reproducer

```
gcc -O3 repro_min.c -o m && ./m
```

`repro_min.c` is 22 lines of straight-line C — no procedure call, no
Fortran front end, no contained subroutine, no derived type. It does
three `(state += K1; s[i] = state * K2)` triples on `int64_t` where
both `K1 = 0x9e3779b97f4a7c15` and `K2 = 0x94d049bb133111eb` have the
high bit set, so the multiplies overflow signed int64. It prints
`s[0]`, `s[1]`, `s[2]` and tests `s[0] != s[2]`.

Output with default flags (any gcc 9.5 through 15.2 we tested):

```
s[0] = 0x7FFFFFFFFFFFFFFF
s[1] = 0x8000000000000000
s[2] = 0x7FFFFFFFFFFFFFFF      <-- printed equal to s[0]
OK: s[0] != s[2]                <-- printed anyway; exit 0
```

The "equal hex / OK branch" combination is not a self-contradiction
inside the optimiser (we initially thought it was — see the section
below on why that framing is wrong). It is the visible artefact of
two independent passes each making sound deductions under the
TYPE_OVERFLOW_UNDEFINED model.

Same source with `-fwrapv`:

```
s[0] = 0xBFA0DD452DD35E32
s[1] = 0xEA7170CF4875AA79
s[2] = 0x154204596317F6C0
OK: s[0] != s[2]
```

The wrapping-arithmetic values now actually differ.

## Flag matrix

`run_flag_matrix.sh <gcc>` runs `repro_min.c` through one gcc binary
at a small grid of flag combinations. On gcc 15.2:

```
  FLAGS                          | s[0]               | s[2]               | rc | VERDICT
  -------------------------------+--------------------+--------------------+----+-------
  -O0                            | 0xBFA0DD452DD35E32 | 0x154204596317F6C0 | 0  | CLEAN
  -O1                            | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0  | FOLD+CHECK_KILLED
  -O2                            | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0  | FOLD+CHECK_KILLED
  -O3                            | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0  | FOLD+CHECK_KILLED
  -O3 -fwrapv                    | 0xBFA0DD452DD35E32 | 0x154204596317F6C0 | 0  | CLEAN
  -O3 -fno-strict-overflow       | 0xBFA0DD452DD35E32 | 0x154204596317F6C0 | 0  | CLEAN
  -O3 -Wstrict-overflow=5        | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0  | FOLD+CHECK_KILLED
```

Reading the grid:

- `-fwrapv` (define wraparound) or `-fno-strict-overflow` (forbid the
  optimiser from assuming overflow is UB) eliminates the miscompile at
  every -O level. Pick either; both work.
- The fold happens at `-O1` already; `-O3` is not load-bearing on the
  minimal C case (the `-O3`-only behaviour in the Fortran case below is
  a function of the larger mixing chain, not of `-O3`).
- `-Wstrict-overflow=5 -Wall -Wextra` is silent. That is not a defect
  in this fold; `-Wstrict-overflow` was deprecated in the gcc-8 changes
  notes (the silencing commit is [r8-3771-g6358a676c3eb4c6df013ce8319bcf429cd14232b](https://gcc.gnu.org/cgit/gcc/commit/?id=6358a676c3eb4c6df013ce8319bcf429cd14232b),
  identified by Jakub Jelinek in [PR 30475 c#65](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=30475#c65)),
  and the open regression tracker is [PR 80511](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=80511).
  Upstream's recommended replacement is `-fsanitize=signed-integer-overflow`
  at runtime.

## Why the optimised output looks contradictory (and why it isn't)

The optimised-tree dump from `gcc -O3 -fdump-tree-optimized` of
`repro_min.c` collapses `main` to a single basic block (gcc 15.2
verbatim):

```
;; Function main (main, funcdef_no=11) (executed once)
int main (int argc, char * * argv)
  <bb 2> [local count: 1073741824]:
  printf ("s[0] = 0x%016llX\n", 9223372036854775807);
  printf ("s[1] = 0x%016llX\n", 9223372036854775808);
  printf ("s[2] = 0x%016llX\n", 9223372036854775807);
  __builtin_puts (&"OK: s[0] != s[2]"[0]);
  return 0;
```

Read literally this looks like the optimiser believes `s[0] == s[2]`
(the printf format arguments) and `s[0] != s[2]` (the chosen rodata
string and `return 0`) simultaneously. That reading is wrong, and is
where our initial bug-report framing failed.

Two different things produce the two facts:

1. **The printed values' equality is UB-conditional.** Under
   TYPE_OVERFLOW_UNDEFINED, `range-op.cc` (`operator_mult::wi_op_overflows`)
   saturates overflowing multiplies to `wi::max_value` / `wi::min_value`
   and *reports `false`* — "no overflow occurred". On the no-UB traces
   the optimiser is licensed to consider, the saturated point-value is
   the only consistent value, so EVRP point-folds `s[0]` and `s[2]` to
   `INT64_MAX` for the printf operands.

2. **The branch elimination is unconditionally correct.** Compute
   `(s[0] - s[2]) mod 2^64` with wrapping arithmetic
   (`-fwrapv` semantics): the answer is `0xAA5ED8EBCABB6772`, nonzero.
   So `s[0] != s[2]` is true under wrapping too. The branch fold is
   not UB-exploitation; it is a correct algebraic simplification an
   optimiser is allowed to make under any signed/unsigned/wrapping
   interpretation.

The two deductions are individually sound; only their visible
co-occurrence in one dump looks contradictory. The optimiser never
holds a value-range object asserting both. This is exactly the kind of
report Andrew Pinski and Jakub Jelinek dispatch in PR 30475: vacuous
truths derived under empty (UB-excluded) trace sets can disagree
pairwise without indicating a soundness defect, and there are ~40
match.pd sites that would each need their own warning hook to flag
this kind of fold individually, which is why `-Wstrict-overflow` was
retired.

## Original Fortran case

The production trigger was `random.f90` in the `dHybridR` relativistic
hybrid plasma simulation. The 48-line Fortran reproducer is
[`repro.f90`](repro.f90):

```
gfortran -O3 repro.f90 -o repro && ./repro
```

```
s(1) = 0x8000000100000000
s(2) = 0x346EDCE5F713F8ED
s(3) = 0x8000000100000000        <-- equal to s(1)
s(4) = 0x2D160E7E5C3F42CA
 OK: four distinct state words   <-- the in-program guard was folded too
```

Compare against `-O0`:

```
s(1) = 0x22118258A9D111A0
s(2) = 0x346EDCE5F713F8ED
s(3) = 0x1E9A57BC80E6721D
s(4) = 0x2D160E7E5C3F42CA
 OK: four distinct state words
```

(On gfortran 9 and older you additionally need `-fno-range-check` so
the front end accepts 64-bit hex literals with the high bit set, like
`z'9e3779b97f4a7c15'`. The flag does not change the optimisation
behaviour being demonstrated.)

The Fortran case is a thicker version of the C reduction. It has the
same root cause (signed int64 multiplies overflow into UB) plus extra
mixing (`ieor` + `ishft` shifts) that lets `-ftree-fre`, `-ftree-vrp`,
and `-finline-small-functions` cooperate to fold the third call's
output to the first's. Disabling any one of those passes hides it.

### What is and isn't required to trigger the Fortran case

Each row below is a separate code variant tested against `-O3`. "BUG"
= `s(1) == s(3)`; "OK" = four distinct values.

| Variant | Result at `-O3` |
|---|---|
| Derived-type `t_rng%s(4)` + contained subroutine *(this repo)* | **BUG** |
| Plain `integer(int64) :: s(4)` + contained subroutine | **BUG** |
| Plain `s(4)` + `do i=1,4` loop calling the contained subroutine | **BUG** (and gfortran emits `-Waggressive-loop-optimizations`: "iteration 1 invokes undefined behavior") |
| Plain `s(4)` + **module** subroutine | OK — needs a contained (internal) procedure |
| Plain `s(4)` + contained **function** form | OK — bug is specific to the subroutine form with separate inout + out args |
| Plain `s(4)` + four fully-inlined splitmix64 bodies | OK — needs the procedure boundary |
| Body shortened to `state = state + 1; z = state * 2` | OK — body must be substantial enough to interest FRE |

### Workarounds (any of these is sufficient)

| Workaround | Effective? |
|---|---|
| **`-fwrapv` on the offending TU** (recommended; one flag, no perf loss elsewhere) | yes |
| **`-fno-strict-overflow` on the offending TU** | yes |
| Drop to `-O2` (or `-O1`, `-Os`, `-Og`) | yes |
| `-O3 -fno-tree-fre` on the offending TU | yes — least drastic if `-fwrapv` is contraindicated |
| `-O3 -fno-inline-small-functions` | yes |
| Move the contained subroutine into a module | yes |
| Manually inline the splitmix64 body at each call site | yes |
| `VOLATILE` attribute on the output argument | **no** |
| `!GCC$ ATTRIBUTES NOINLINE` on the subroutine | **no** |

In `dHybridR` the production fix is a per-source-file CMake override:

```cmake
set_source_files_properties(random.f90 PROPERTIES COMPILE_OPTIONS "-fwrapv")
```

## Why this matters operationally

The defect survived all sanity checks because the failure mode was
"wrong physics, plausible numbers", not "crash" or "NaN". The
`xoshiro256**` state was seeded with `s(1) == s(3)`, so the RNG
produced identical 64-bit values on alternating draws. Maxwellian
particle velocity samples drawn from that RNG looked plausible —
bell-shaped, right mean and variance — but were silently correlated
across particle pairs, contaminating every stochastic outcome of the
simulation.

The take-aways for downstream Fortran code that does multiplicative
hashing or RNG seeding with int64 constants that have the high bit
set:

1. Audit for `integer(int64)` multiplies of hex constants ≥ `z'8000000000000000'`.
2. Add `-fwrapv` (or `-fno-strict-overflow`) for any source file doing
   that arithmetic intentionally, per-file via
   `set_source_files_properties` so the rest of the build keeps the
   default optimisation model.
3. Don't rely on in-program guards like `if (s(1) == s(3)) stop 1` —
   the same fold that produces the degenerate state will also fold
   the guard.

## CI matrix

The [`demonstrate-bug` workflow](.github/workflows/demonstrate.yml)
compiles `repro.f90` at `-O0`, `-O1`, `-O2`, `-O3` across:

- **Ubuntu 22.04** (x86_64): gfortran 9, 10, 11, 12.
- **Ubuntu 24.04** (x86_64): gfortran 12, 13, 14, 15.
- **macOS 13 / 14** (x86_64 / arm64): Homebrew gcc@13, gcc@14, gcc@15.

For each cell the CI parses the four hex words from stdout and decides
`BUG` / `OK` by `s(1) == s(3) -> BUG`. The expected pattern is
`O0=OK, O1=OK, O2=OK, O3=BUG`. See the
[Actions tab](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions)
for live results.

### Intel ifx (control case)

The same `repro.f90` compiled with Intel `ifx` does NOT exhibit the
symptom at any optimisation level. `ifx` is more conservative about
exploiting signed-overflow UB on this pattern; this is a difference in
*policy*, not a contradiction. The Intel oneAPI install is provided by
the public composite action
[`Migelo/setup-intel-oneapi`](https://github.com/Migelo/setup-intel-oneapi).

### NVIDIA nvfortran (control case)

The same `repro.f90` compiled with NVIDIA `nvfortran` 25.11 does NOT
exhibit the symptom at any optimisation level. Same caveat as above —
this is policy, not soundness.

## Status

Not filed as a gcc bugzilla report. The minimal C reproducer is a
textbook instance of the [PR 30475](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=30475)
(RESOLVED INVALID, 2007) class of signed-overflow UB exploitation;
the missing `-Wstrict-overflow` diagnostic is tracked separately in
[PR 80511](https://gcc.gnu.org/bugzilla/show_bug.cgi?id=80511) (open).
The on-topic upstream contribution, if any, would be attaching
`repro_min.c` to PR 80511 as one more match.pd site whose fold no
longer warns. The repository's value is downstream: a clear minimal
reproducer, an honest flag matrix, and a worked example of the
per-file CMake fix that scientific-code projects can copy.
