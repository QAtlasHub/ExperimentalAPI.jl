```@meta
CurrentModule = ExperimentalAPI
DocTestSetup = quote
    using ExperimentalAPI
end
```

```@setup observing
using ExperimentalAPI
module MyModel
using ExperimentalAPI
public energy, step, sweep, simulate
@experimental "convergence not established below β ≈ 0.1" energy(β::Float64) = -log(2cosh(β)) / β
step(β::Float64) = energy(β) + tanh(β)
sweep(βs::Vector{Float64}) = (t = 0.0; for β in βs; t += step(β); end; t)
simulate(βs::Vector{Float64}; steps::Int = 1) = (t = 0.0; for _ in 1:steps; t += sweep(βs); end; t)
end
βs = collect(0.05:0.05:2.0)
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

```@repl observing
MyModel.energy(0.5)
ExperimentalAPI.entered(MyModel)
```

Asked about a module rather than about the whole process, because the process-wide answer includes
every marked package loaded — on this page, the fixtures the documentation built. The fields it is
read for do not depend on where it ran, and those are checked as a doctest:

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

```@example observing
r = ExperimentalAPI.record(; paths = false) do
    MyModel.simulate(βs; steps = 500)
end
nothing # hide
```

```@example observing
r
```

`paths = false` here because a captured path is the whole call stack, and on this page that starts
at `_start` and runs through `makedocs`. The timings are `missing`: a documentation build does not
load `Profile`, and `record` reports what it measured rather than a zero.

[`record`](@ref) returns a `Vector`-like of [`Hit`](@ref), so `isempty(r)` and `r[1].count` read
the way they look — with the properties an empty vector could not carry:

| property | why it is not just a vector |
|---|---|
| `enabled` | an empty record means "nothing was entered"; without this it is indistinguishable from "nothing was recorded", and those are opposite statements |
| `slots` | thread slots the counters were sized for, at least `Threads.maxthreadid()` — the interactive pool means a task's thread id can exceed `nthreads()` |
| `overhead` | the recorder's estimated share of the elapsed time, from a calibrated per-hit cost |
| `versions` | `energy` being experimental in v0.3 says nothing about v0.9 |

### Asking about one call

`record(() -> f(x))` is the function form, and it is what everything here is built on.
[`@entered`](@ref) is the same question asked about an expression, and it knows two things a
closure cannot — the source text of the call and the line it is written on:

```@example observing
report = IOBuffer()
value = ExperimentalAPI.@entered report MyModel.sweep(βs)
print(String(take!(report)))
```

The footer counts every observable marked definition **loaded in the process**, not only the ones
in your package.

It returns the value of the expression, so it drops into existing code the way `@time` does — with
one divergence `@time` does not have, since `record` takes a function and the expression therefore
runs inside a closure: a `return` inside it returns from the closure, and `@entered y = f(x)` binds
`y` inside the closure. Write `y = @entered f(x)`. The last line is what makes a clean answer mean
anything:

```@example observing
ExperimentalAPI.@entered report round(1.0; digits = 2)
print(String(take!(report)))
```

"Entered nothing" and "nothing is marked anywhere" are different states, and a package that has
not adopted this yet is in the second one. A report that could not tell them apart would read as
reassurance on a package where nothing had ever been declared.

What it returns is the record's `value` — `record` carries the block's result out, so measuring a
call does not cost you that result. It is `record(() -> expr; paths = false, timing = false)` plus
the report: the cheap question, `which` and `how often`, needing neither a backtrace nor a sampler.
For call paths, time (never both — see [`record`](@ref)), or the [`Record`](@ref) as data, call
[`record`](@ref).

Name an `io` first to send the report somewhere else — `@entered log sweep(model)` into a file,
`@entered devnull f(x)` to keep only the value. The default is looked up when the block runs, not
when the macro expands, so `redirect_stdout` still catches it.

The route is deliberately not printed: a captured path is a list of frame names, and Base's
higher-order functions are in it. Measured for `driver(x, n) = sum(inner(x) for _ in 1:n)`, the
captured path runs `driver → sum → #sum#278 → sum → #sum#277 → mapreduce → #mapreduce#274 →
mapfoldl → #mapfoldl#270 → mapfoldl_impl → foldl_impl → _foldl_impl → MappingRF → #driver##0 →
inner → energy` — three names the reader wrote and thirteen they did not. Separating the two needs
`paths` to carry which module each frame came from, which is a change to what
[`Hit`](@ref)`.paths` means.

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
ExperimentalAPI.assert_clean() do
    publish(compute(model))
end
```

[`write_record`](@ref) and [`stamp`](@ref) write it down instead. Both produce plain TOML, because
a year later the package that made the figure may not resolve — and a provenance record nobody can
open is not one.
