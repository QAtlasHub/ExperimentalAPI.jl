# ExperimentalAPI.jl

[![docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://qatlashub.github.io/ExperimentalAPI.jl/dev/)
[![codecov](https://codecov.io/gh/QAtlasHub/ExperimentalAPI.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/QAtlasHub/ExperimentalAPI.jl)
[![Julia](https://img.shields.io/badge/julia-v1.11+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Mark a definition as not settled yet, and find out when a run went through one.

I publish reference values for physical models that have exact solutions. Which regime and which
conditions give which answer branches heavily, so a stable API is hard to settle on — and
separately, a numerical result can fail to converge to the true value with no way to be certain.
Sometimes that uncertainty *is* the limit of the paper, or of the theory.

That belongs in the docstring. But a docstring is a layer for people; this is meant to be the
layer a machine reads. The idea comes from Lean 4's `sorry`, which lets a development be checked
end to end with an unproven proposition still standing in it. A mark on my own code means I am not
yet sure it behaves well — and because it is a macro rather than prose, a run can tell me it went
through one.

```julia
using ExperimentalAPI

@experimental "convergence not established below β ≈ 0.1" energy(β) = β * 1.0000001

energy(0.5)
```

```console
$ julia sweep.jl
┌ ExperimentalAPI: this run entered 1 experimental definition
│   Main.energy — convergence not established below β ≈ 0.1
└ set ENV["EXPERIMENTALAPI_SUMMARY"] = "0" before `using` to silence this
```

On by default, silent when nothing marked was entered, and carrying the reason rather than just
the symbol. [`entered()`](https://qatlashub.github.io/ExperimentalAPI.jl/dev/observing/) returns
the same thing as data. The flag costs 1.03× on one thread and 0.985× on eight; the
[measurements](https://qatlashub.github.io/ExperimentalAPI.jl/dev/observing/#What-it-costs) are in
the docs.

`ExperimentalAPI.test_surface(MyPackage)` in `runtests.jl` asserts that every public name has a
docstring, and that no mark points at a name that was never made public. **A mark is not a
substitute for prose** — it records that a shape is unsettled, which is never a reason to say
nothing about what the name does.

Two further questions, both opt-in.
[`record(f)`](https://qatlashub.github.io/ExperimentalAPI.jl/dev/observing/#Recording:-counts,-paths-and-time)
counts how often a run entered each mark, by which paths, and how much of the run it was — exactly,
without emitting anything the flag above does not already emit.
[`reach(f, T)`](https://qatlashub.github.io/ExperimentalAPI.jl/dev/analysing/) asks the other
question, before running anything: what a caller depends on without naming it. Its answer is
three-valued, because Julia's call graph is not closed — `:depends`, `:clean`, and `:unknown` for
a call site that cannot be pinned to a method. Reporting that third case as `:clean` would not be
a weaker claim, it would be a false one.

## Install

```julia
pkg> add https://github.com/QAtlasHub/ExperimentalAPI.jl
```

## Documentation

[Declaring](https://qatlashub.github.io/ExperimentalAPI.jl/dev/declaring/) ·
[Observing](https://qatlashub.github.io/ExperimentalAPI.jl/dev/observing/) ·
[Analysing](https://qatlashub.github.io/ExperimentalAPI.jl/dev/analysing/) ·
[Checking](https://qatlashub.github.io/ExperimentalAPI.jl/dev/checking/) ·
[Release decisions](https://qatlashub.github.io/ExperimentalAPI.jl/dev/releases/) ·
[Adopting it](https://qatlashub.github.io/ExperimentalAPI.jl/dev/adopting/) ·
[API](https://qatlashub.github.io/ExperimentalAPI.jl/dev/api/)

`test/spec/` is the specification, written as tests before the implementation so it could not
drift from the code — 176 behaviours across ten files, all of them live assertions. Its
[README](test/spec/README.md) records the negative control each group has, the two requirements
that were withdrawn and why one of them could not be met, and the four defects the exercise found
in the shipped code.

## Development

This package is written with the assistance of [Claude Code](https://claude.com/claude-code). The
design is mine: the mark as a machine-readable layer beside the docstring, the analogy to Lean's
`sorry`, and reporting what a run entered. The implementation, the test suite and the reference
documentation are LLM-assisted and reviewed by me before merging.

## License

MIT
