```@meta
CurrentModule = ExperimentalAPI
DocTestSetup = quote
    using ExperimentalAPI
end
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

The display above is a transcript rather than a doctest on purpose: `Entry` prints its module, and
Documenter evaluates doctests in a sandbox whose module does not print as `Main`, so a doctest here
would show a line no reader ever sees at their own REPL. The fields it is read for do not depend on
where it ran, so those are checked:

```jldoctest
julia> using ExperimentalAPI

julia> @experimental "convergence not established below β ≈ 0.1" energy(β) = β * 1.0000001

julia> energy(0.5);

julia> only(ExperimentalAPI.entered()).name
:energy

julia> only(ExperimentalAPI.entered()).reason
"convergence not established below β ≈ 0.1"

julia> only(ExperimentalAPI.entered()).count === nothing
true
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

## What the default layer does not answer

  * **How often.** Presence only — [`Entry`](@ref)`.count` is always `nothing`.
  * **Which method.** Flags are name-keyed, so two methods of a marked name share one.
  * **Which call site, or by what path.**
  * **Anything about a declaration-only mark.** A name list, a `struct`, a `const`, a `module`:
    recorded and audited, never observed. See [`@experimental`](@ref) for the table.

The first three are [`record`](@ref)'s, and it is a call rather than a default because of the
table above.

## Recording: counts, paths and time

```julia
r = record() do
    simulate(model; steps = 10_000)
end
```

```julia
julia> r
Record — 1 marked definition entered in 0.42s
  MyModel.energy  ×10000 — convergence not established below β ≈ 0.1
     inclusive 0.31s   exclusive 0.28s
     via record → sweep → step → energy
  recorder overhead ≈ 4.1%
```

[`record`](@ref) returns a `Vector`-like of [`Hit`](@ref), so `isempty(r)` and `r[1].count` read
the way they look — with the properties an empty vector could not carry:

| property | why it is not just a vector |
|---|---|
| `enabled` | an empty record means "nothing was entered"; without this it is indistinguishable from "nothing was recorded", and those are opposite statements |
| `slots` | thread slots the counters were sized for, at least `Threads.maxthreadid()` — the interactive pool means a task's thread id can exceed `nthreads()` |
| `overhead` | the recorder's estimated share of the elapsed time, from a calibrated per-hit cost |
| `versions` | `energy` being experimental in v0.3 says nothing about v0.9 |

### How it counts without a counter in the body

The emitted statement never changes. Opening a block clears every probe's flag, so the
short-circuit fails and the *write* side runs on every call — and the write side is a function
call, not an inlined store, so it can afford to count. Counts are therefore **exact** and survive
inlining, which is what ruled out the sampling route: a definition small enough to be worth
marking is small enough to be inlined, and a sampler has no frame left to attribute to.

Counts are exact under threads too: per-thread counters, sized by `maxthreadid()` and padded so
two threads never share a cache line, summed at the end.

`paths` is a bounded sample rather than a complete list — a backtrace costs microseconds, so the
recorder stops looking once it has seen enough. The paths a marked definition is reached by are
few and repeat.

### Time

`inclusive` and `exclusive` come from Julia's sampling profiler, through a package extension:
without `using Profile` they are `missing`, which is not zero. A run that nobody timed has no
fraction to report, and `0.0` would say the opposite.

[`experimental_fraction`](@ref) is the share of the run spent inside marked code, derived from the
inclusive times — so it is time and not calls. One entry into a marked kernel that runs for a
minute matters more than a million into a marked accessor.

[`attribute`](@ref) does the same for a profile buffer that already exists, which is the
twelve-hour-run case: a job that was already profiled must not have to be run again. What comes
back is [`Attribution`](@ref) — samples, never calls, because a sampling profiler cannot count
entries and a field called `count` holding a sample total would read as a measurement it did not
make.

### As a gate, and as evidence

[`assert_clean`](@ref) turns a record into a refusal:

```julia
assert_clean() do
    publish(compute(model))
end
```

[`write_record`](@ref) and [`stamp`](@ref) write it down instead. Both produce plain TOML, because
a year later the package that made the figure may not resolve — and a provenance record nobody can
open is not one.
