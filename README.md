# gfortran -O3 miscompiles consecutive calls to a contained subroutine with intent(inout)

[![demonstrate-bug](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions/workflows/demonstrate.yml/badge.svg)](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions/workflows/demonstrate.yml)

## TL;DR

`gcc` 9.5 through 15.2 at `-O2`/`-O3` emit a basic block that prints two
signed-int64 values as the same hex constant (`0x7FFFFFFFFFFFFFFF`,
i.e. `INT64_MAX`) and immediately afterwards takes the `a != b` branch
on those values. The optimiser's range pass folds the two values to the
same point-value AND simultaneously concludes that they cannot be equal,
in the same pass. Adding `-fwrapv` or `-fno-strict-overflow` makes the
miscompile go away at every -O level. The 22-line minimal C reproducer
is [`repro_min.c`](repro_min.c); the original Fortran case is
[`repro.f90`](repro.f90), where the same fold silently corrupted the
RNG state of a production plasma simulation.

The original Fortran case manifests only at `-O3`, in a SplitMix64 step
used to initialise an `xoshiro256**` state for the `dHybridR` simulation;
the third call to a contained subroutine returns the same `z` as the
first, so `s(1) == s(3)`. Per-pass bisection on the Fortran case points
at `-ftree-fre` (Full Redundancy Elimination), `-ftree-vrp` (Value Range
Propagation), and the inliner (`-finline-small-functions`): adding any
one of `-fno-tree-fre`, `-fno-tree-vrp`, or `-fno-inline-small-functions`
to `-O3` makes the bug go away. So does moving the subroutine out of
`contains` into its own module. Observed on the live CI matrix in this
repo (see the [Actions tab](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions)).

## Reproduce yourself (minimal: 22 lines of C)

```
gcc -O3 repro_min.c -o m && ./m; echo exit=$?
```

`repro_min.c` is a 22-line straight-line C program — no procedure call,
no Fortran front end, no contained subroutine, no derived type. It does
three `(state += K1; s[i] = state * K2)` triples on `int64_t` where both
`K1` and `K2` have the high bit set (so the multiplies overflow signed
int64). It then prints `s[0]`, `s[1]`, `s[2]` and asserts `s[0] != s[2]`.

What you see on every gcc we tested (9.5 / 10.1 / 11.1 / 12.1 / 14.1 /
15.2, all self-built on x86_64 linux) is:

```
s[0] = 0x7FFFFFFFFFFFFFFF
s[1] = 0x8000000000000000
s[2] = 0x7FFFFFFFFFFFFFFF   <-- equal to s[0]
OK: s[0] != s[2]            <-- printed anyway; exit 0
```

The same gcc, same source, with one extra flag:

```
gcc -O3 -fwrapv repro_min.c -o m && ./m
s[0] = 0xBFA0DD452DD35E32
s[1] = 0xEA7170CF4875AA79
s[2] = 0x154204596317F6C0
OK: s[0] != s[2]            <-- exit 0, and now actually true
```

The C reproducer demonstrates the gcc-side root cause: signed-overflow
range reasoning in EVRP. The original Fortran reproducer (`repro.f90`,
below) is the production case that exposed it.

## Flag influence

`run_flag_matrix.sh` runs `repro_min.c` through one gcc binary at a
small grid of flag combinations. The output on gcc 15.2 is:

```
  FLAGS                          | s[0]               | s[2]               | rc  | VERDICT
  -------------------------------+--------------------+--------------------+-----+-------
  -O0                            | 0xBFA0DD452DD35E32 | 0x154204596317F6C0 | 0   | CLEAN
  -O1                            | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0   | FOLD+CHECK_KILLED
  -O2                            | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0   | FOLD+CHECK_KILLED
  -O3                            | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0   | FOLD+CHECK_KILLED
  -O3 -fwrapv                    | 0xBFA0DD452DD35E32 | 0x154204596317F6C0 | 0   | CLEAN
  -O3 -fno-strict-overflow       | 0xBFA0DD452DD35E32 | 0x154204596317F6C0 | 0   | CLEAN
  -O3 -Wstrict-overflow=5        | 0x7FFFFFFFFFFFFFFF | 0x7FFFFFFFFFFFFFFF | 0   | FOLD+CHECK_KILLED
```

Three things this grid is meant to make obvious:

1. **The two opt-out flags work.** Either `-fwrapv` (define wraparound)
   or `-fno-strict-overflow` (forbid the optimiser from assuming overflow
   is UB) eliminates the miscompile at every -O level.
2. **The diagnostic is silent.** `-O3 -Wstrict-overflow=5 -Wall -Wextra`
   on this code emits no warning at any level from N=1 to N=5 on any of
   the six gcc versions we tested. The bisect we did (see
   `gcc/vr-values.c` in gcc-10.5 vs gcc-15.2) shows the
   `warn_strict_overflow` hook that used to live in
   `vrp_evaluate_conditional` was removed during the Ranger rewrite in
   the gcc-12 era. There is now no policy mechanism announcing the fold.
3. **`-O1` is enough.** On the minimal C reproducer the miscompile is
   not gated on `-O3`-specific passes; `-O1` already exhibits it. The
   `-O3`-only behaviour the Fortran section below reports is a function
   of the larger Fortran mixing chain (full splitmix64 with shifts and
   xors), not of `-O3` itself.

## The EVRP self-inconsistency (the recent find)

Compile the program with `-O3 -fdump-tree-optimized=optimized.dump` and
read `optimized.dump`. The body of `main` is collapsed to a single basic
block (gcc 15.2 output, verbatim):

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

That basic block contains two EVRP deductions about the same SSA values,
side by side:

- **Point-fold:** `s[0]` and `s[2]` both fold to `INT64_MAX` (the
  saturation value the signed-overflow chain saturates at). Visible in
  the printf constants and in the hex output the program prints.
- **Range-relation:** `s[0] != s[2]` is constant true. Visible in the
  choice of rodata string (`"OK: s[0] != s[2]"`, not the BUG branch)
  and in the unconditional `return 0`.

These cannot both be true. The first deduction says the values are
equal; the second says they are unequal. Both come out of the same
pass.

The standard upstream response to "gcc miscompiles signed overflow at
-O3" is WONTFIX since 2007 (PR 30475), on the grounds that signed
overflow is UB and the user must opt out via `-fwrapv` or
`-fno-strict-overflow`. That is policy and not under dispute here.
What this section is reporting separately is that the optimiser's own
range model is internally inconsistent on this fold: it simultaneously
believes the two values are equal and unequal. That self-inconsistency
is independent of the UB-exploitation policy.

## Reproduce the Fortran case

```
gfortran -O3 repro.f90 -o repro && ./repro
```

That's it. Compare against `-O0`:

```
gfortran -O0 repro.f90 -o repro_ok && ./repro_ok
```

(On gfortran 9 and older you may additionally need `-fno-range-check`,
which lets the compiler accept the 64-bit hex literals like
`z'9e3779b97f4a7c15'` whose high bit is set. The flag does not affect
the bug being demonstrated — it is a Fortran-language compatibility
knob for older compilers.)

## Expected vs actual output

```
$ gfortran -O3 repro.f90 -o repro && ./repro      # WRONG
s(1) = 0x8000000100000000
s(2) = 0x346EDCE5F713F8ED
s(3) = 0x8000000100000000        <-- identical to s(1)
s(4) = 0x2D160E7E5C3F42CA
 OK: four distinct state words   <-- IF was folded at compile time; wrong

$ gfortran -O0 repro.f90 -o repro && ./repro      # CORRECT
s(1) = 0x22118258A9D111A0
s(2) = 0x346EDCE5F713F8ED
s(3) = 0x1E9A57BC80E6721D
s(4) = 0x2D160E7E5C3F42CA
 OK: four distinct state words
```

Note that the `if (s(1) == s(3) ...) stop 1` guard inside `repro.f90` is
**itself folded away at `-O3` using the (incorrect) value numbering**, so
the program prints "OK" and exits 0 even when its own state is degenerate.
The CI in this repo therefore detects the bug by parsing the printed hex
words, not by the program's exit code.

## What is and isn't required to trigger

Each row below is a separate code variant tested against `-O3` (no other
flags). "BUG" = `s(1) == s(3)`; "OK" = four distinct values.

| Variant | Result at `-O3` |
|---|---|
| Derived-type `t_rng%s(4)` + contained subroutine *(this repo)* | **BUG** |
| Plain `integer(int64) :: s(4)` + contained subroutine | **BUG** — derived type is not required |
| Plain `s(4)` + `do i=1,4` loop calling the contained subroutine | **BUG** — and gfortran emits `-Waggressive-loop-optimizations` ("iteration 1 invokes undefined behavior"); all four words collapse |
| Plain `s(4)` + **module** subroutine (separate `module m_repro contains …`) | OK — must be a *contained* (internal) procedure |
| Plain `s(4)` + contained **function** (single inout state, returns z) | OK — bug is specific to the subroutine form with separate inout + out args |
| Plain `s(4)` + four fully-inlined splitmix64 bodies (no procedure call) | OK — bug needs the procedure boundary |
| Body shortened to `state = state + 1; z = state * 2` | OK — body must be substantial enough to interest FRE |
| Body shortened to splitmix64 minus the last `ieor(z, ishft(z,-31))` line | OK — full splitmix64 mixing is needed |

Minimum recipe:

1. A **contained (internal) subroutine** — module form does not reproduce.
2. Subroutine has both `intent(inout) :: state` and `intent(out) :: z` arguments.
3. The caller invokes it >= 4 times in a row, passing the *same* `state`
   and successive array elements as `z`.
4. The body must include enough mixing (xor + shift + multiply) for the
   gfortran inliner to emit non-trivial SSA — full splitmix64 triggers;
   `state+1; z=state*2` does not.

Not required: LTO, `-funroll-loops`, `-fopenmp-simd`, `-faggressive-loop-optimizations`,
`-fipa-modref`, `-fipa-pure-const`, `-ftree-sra`, `-ftree-pre`,
`-ftree-dse`, `-ftree-forwprop`, `-ftree-copy-prop`. Disabling any one of
these still leaves the bug.

## Workarounds

These are workarounds, **not fixes**:

| Workaround | Effective? |
|---|---|
| Drop to `-O2` (or `-O1`, `-Os`, `-Og`) | yes |
| Compile only the offending TU with `-O0` (`set_source_files_properties(... -O0)` in CMake) | yes |
| Compile only the offending TU with `-O3 -fno-tree-fre` | yes — least drastic |
| `-O3 -fno-inline-small-functions` | yes |
| Convert the contained subroutine to a module subroutine in a separate file | yes |
| Convert to a function form (single inout state arg, returns z) | yes |
| Manually inline the four splitmix64 bodies at the call site | yes |
| `VOLATILE` attribute on the output argument | **no** (verified in upstream project) |
| `!GCC$ ATTRIBUTES NOINLINE` on the subroutine | **no** (verified in upstream project) |
| Drop `-flto` | **no** — the bug fires without `-flto` |

## Why this matters

This bug silently miscompiled the RNG initialization in `dHybridR`
(a relativistic hybrid plasma simulation). The xoshiro256** state was
seeded with `s(1) == s(3)`, so the RNG produced identical 64-bit values
on alternating draws. Maxwellian particle velocity samples drawn from
that RNG looked plausible — bell-shaped, right mean and variance — but
were silently correlated across particle pairs, contaminating every
stochastic outcome in the simulation. The defect survived all
sanity checks because the failure mode was "wrong physics, plausible
numbers", not "crash" or "NaN".

The fix in production was a per-source-file CMake override pinning
`random.f90` to `-O0` (later relaxed to `-fno-tree-fre`), plus a hardened
RNG init that manually inlines the splitmix64 body four times — neither
the `VOLATILE` nor `!GCC$ ATTRIBUTES NOINLINE` workarounds were effective.

## Status

GCC Bugzilla report: to be filed at https://gcc.gnu.org/bugzilla/.
This repository will be linked from that report so any developer can
re-run the live CI matrix and see the bug reproduce on demand.

The angle worth filing on is the **EVRP self-inconsistency** (see the
section above), not the raw signed-overflow miscompile — that part is
well-trodden ground (PR 30475, WONTFIX since 2007). The optimised-tree
dump from `repro_min.c` is the minimal artefact: a single basic block
in which the pass simultaneously folds two SSA values to the same
constant and concludes that they cannot be equal. The miscompile is a
consequence of that inconsistency; the inconsistency is the bug.

## CI matrix

The [`demonstrate-bug` workflow](.github/workflows/demonstrate.yml)
compiles `repro.f90` at `-O0`, `-O1`, `-O2`, `-O3` against multiple
gfortran versions on multiple OS / architecture combinations:

- **Ubuntu 22.04** (x86_64): gfortran 9, 10, 11, 12.
- **Ubuntu 24.04** (x86_64): gfortran 12, 13, 14.
- **macOS 13** (x86_64): Homebrew gcc@13, gcc@14, gcc@15.
- **macOS 14** (arm64):  Homebrew gcc@13, gcc@14, gcc@15.

For each cell the CI parses the four hex words from the program's stdout
and decides `BUG` / `OK` from the rule `s(1) == s(3) -> BUG`. The
expected and currently-observed pattern is `O0=OK, O1=OK, O2=OK, O3=BUG`.
A cell whose pattern deviates from that is flagged in red — for example,
a gfortran version that has already fixed the bug, or one that exhibits
it at a different optimization level. See the
[Actions tab](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions)
for the latest results.

You can re-trigger the matrix at any time via "Run workflow" on the
Actions page (the workflow has a `workflow_dispatch` trigger).

### Intel ifx (control case)

The same `repro.f90` compiled with Intel `ifx` (from oneAPI) does NOT
exhibit the bug at any optimization level (`-O0`, `-O1`, `-O2`, `-O3`),
demonstrating that the misbehaviour is specific to gfortran's
FRE / early-VRP / small-function-inliner pass cluster and not a
Fortran-standard ambiguity in the reproducer. The `intel-ifx` matrix
in the workflow runs as a control. The Intel oneAPI install is
provided by the public composite action
[`Migelo/setup-intel-oneapi`](https://github.com/Migelo/setup-intel-oneapi).

### NVIDIA nvfortran (control case)

The same `repro.f90` compiled with NVIDIA `nvfortran` (from the HPC SDK
25.11, run inside the official `nvcr.io/nvidia/nvhpc:25.11-devel-cuda13.0-ubuntu24.04`
container) does NOT exhibit the bug at any optimization level
(`-O0`, `-O1`, `-O2`, `-O3`), providing a third independent
Fortran-compiler data point. Combined with the Intel `ifx` matrix, this
shows the bug is specific to gfortran's FRE / early-VRP / small-function-
inliner pass cluster after inlining a contained subroutine with the
`intent(inout) :: state` / `intent(out) :: z` argument split — not a
Fortran-standard ambiguity in the reproducer. The `nvfortran` matrix in
the workflow runs as an additional control alongside `intel-ifx`.
