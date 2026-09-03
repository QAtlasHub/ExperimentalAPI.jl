```@meta
CurrentModule = ExperimentalAPI
```

# Observing

A docstring can say a name is unfinished. It cannot tell you that *this run* went through it.

That is the question behind the mark: not "is `energy` experimental", which the author already
knows, but "did the number in this figure come out of code nobody validated" — asked after the
run, about the run, by somebody who may not have written either.

## Without asking

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

Three properties, each of them a decision:

  * **On by default.** The user who never asks is the one who needs telling. [`detecting`](@ref)
    reports whether the hook is armed; the environment variable has to be set *before*
    `using ExperimentalAPI`, because that is when `atexit` is registered.
  * **Silent unless something was entered.** Loading a package that *has* marks prints nothing.
    A package that cannot be quiet is one people vendor around.
  * **Carries the reason.** The name says which line to open; the reason says whether the result
    is affected.

## As data

[`entered`](@ref) returns the same thing the summary prints, as a `Vector{`[`Entry`](@ref)`}`:

```julia
julia> ExperimentalAPI.entered()
1-element Vector{ExperimentalAPI.Entry}:
 Entry(Main.energy, "convergence not established below β ≈ 0.1")
```

A marked definition the run never entered is **absent**, not reported with a count of zero — the
difference between "observed" and "enumerated".

[`marked_modules`](@ref) is the search this uses: the loaded modules that carry marks, found by
walking rather than by a registry inside this package, because a table here would be written
while the *marked* package is precompiled and so would be missing from its cache image.
[`summary_text`](@ref) is what the exit hook prints, available as a string for a report of your
own.

## What it costs

One short-circuit read in the body, and a write on the first call only.

| emitted into the body | 1 thread | 8 threads | counts correctly? |
|---|---|---|---|
| nothing | 1.00× | 1.00× | — |
| **the flag `@experimental` emits** | 1.03× | **0.985×** | yes |
| a counter, plain shared `Ref` | 1.03× | 3.76× | **no** — 40% lost to races |
| a counter, global atomic | 1.17× | 4.87× | yes |
| a counter, per-thread atomic | 1.12× | 2.79× | yes |
| `@warn`, guarded so it fires once | 5.65× | — | yes |
| `@warn maxlog=1` | 59.57× | — | yes |

10M calls of `sqrt(abs(sin(x)cos(x) + exp(-|x|/1e6)))`, minimum of 7–9 trials, Julia 1.12.2.

Two of those rows decided the design. A flag written once and only read afterwards stops dirtying
the cache line, which is why it is free at eight threads while every counting scheme is not. And
the guarded `@warn` costs 5.65× *even though it fires once*: what stops the definition inlining is
the call being in the body at all, not the warning being printed. That is why the notice is a
summary at exit rather than a warning at the call.

## What it does not answer

  * **How often.** Presence only — [`Entry`](@ref)`.count` is always `nothing`. Counting is an
    opt-in layer that is not built yet.
  * **Which method.** Marks are name-keyed, so two methods of a marked name share one flag.
  * **Which call site, or by what path.** Also the opt-in layer.
  * **Anything about a declaration-only mark.** A name list, a `struct`, a `const`, a `module`:
    recorded and audited, never observed. See [`@experimental`](@ref) for the table.
