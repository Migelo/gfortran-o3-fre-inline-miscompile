# gfortran -O3 miscompiles consecutive calls to a contained subroutine with intent(inout)

[![demonstrate-bug](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions/workflows/demonstrate.yml/badge.svg)](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions/workflows/demonstrate.yml)

## TL;DR

`gfortran` 15.2 (at least) at `-O3` constant-folds the output of
consecutive calls to an inlined **contained (internal) subroutine** whose
signature is `(intent(inout) :: state, intent(out) :: z)`. The third call
returns the same `z` as the first. The 48-line reproducer in this repo is a
SplitMix64 step used to initialize an `xoshiro256**` RNG state; at `-O3`
the cold-start state comes out with `s(1) == s(3)` instead of four
distinct 64-bit values. Observed on the live CI matrix in this repo
(see the [Actions tab](https://github.com/Migelo/gfortran-o3-fre-inline-miscompile/actions)).

The bug only appears at `-O3`. `-O0`, `-O1`, `-O2`, `-Os`, `-Og` are all
fine. Per-pass bisection points at `-ftree-fre` (Full Redundancy
Elimination), `-ftree-vrp` (Value Range Propagation), and the inliner
(`-finline-small-functions`): adding any one of `-fno-tree-fre`,
`-fno-tree-vrp`, or `-fno-inline-small-functions` to `-O3` makes the bug
go away. So does moving the subroutine out of `contains` into its own
module.

## Reproduce yourself

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
