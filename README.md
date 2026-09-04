# ExperimentalAPI.jl

[![docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://qatlashub.github.io/ExperimentalAPI.jl/dev/)
[![codecov](https://codecov.io/gh/QAtlasHub/ExperimentalAPI.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/QAtlasHub/ExperimentalAPI.jl)
[![Julia](https://img.shields.io/badge/julia-v1.11+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

`public` says who may call a name. Nothing says whether the name is *finished* — and nothing tells
you, after a twelve-hour run, that the number you are about to publish came out of code its author
had not validated.

`@experimental` is that mark, written at the definition site where the author is, and readable by
a machine so the answer arrives without anyone remembering to ask for it.

```julia
using ExperimentalAPI

@experimental "convergence not established below β ≈ 0.1" energy(β) = β * 1.0000001

energy(0.5)
```

Run that file and it ends by telling you something you did not ask for:

```console
$ julia sweep.jl
┌ ExperimentalAPI: this run entered 1 experimental definition
│   Main.energy — convergence not established below β ≈ 0.1
└ set ENV["EXPERIMENTALAPI_SUMMARY"] = "0" before `using` to silence this
```

It is on by default, it carries the **reason** rather than just the symbol, and a marked
definition the run never entered is *absent* — not reported with a count of zero. The same answer
is available programmatically:

```julia
julia> ExperimentalAPI.entered()
1-element Vector{ExperimentalAPI.Entry}:
 Entry(Main.energy, "convergence not established below β ≈ 0.1")
```

That example is executed verbatim by `test/test_readme.jl`, so it cannot rot.

## What it costs

A read, plus one write on the first call:

| emitted into the body | 1 thread | 8 threads |
|---|---|---|
| nothing | 1.00× | 1.00× |
| **the flag `@experimental` emits** | 1.03× | **0.985×** |
| a counter, plain shared `Ref` | 1.03× | 3.76× — and loses 40% of its increments to races |
| a counter, global atomic | 1.17× | 4.87× |
| `@warn`, guarded so it fires once | 5.65× | — |

10M calls of `sqrt(abs(sin(x)cos(x) + exp(-|x|/1e6)))`, minimum of 7–9 trials, Julia 1.12.2. The
flag is written once and only read afterwards, so it stops dirtying the cache line — which is why
it is free at eight threads while every counting scheme is not, and why the notice is a summary at
exit rather than a warning at the call. Counting, call sites and paths are a separate, opt-in
layer — `record`, below — and it reaches the same statement from the other side rather than
emitting anything more.

Only a definition **with a body** carries a flag — `function`, `f(x) = …`, parametric and
return-type-annotated signatures alike. A mark written as a name list, or attached to a struct, a
const or a module, is a declaration: queryable, and part of the audit below, but nothing observes
it at run time. One flag per marked *name*, so two methods of a marked name share it.

## It is also a check

**A mark is not a substitute for a docstring.** Every public name should have one; the mark is a
second, independent account — the docstring says what the name does, the mark says whether its
shape is settled. A marked name with no prose fails the check exactly as an unmarked one does,
and there is no switch that turns that off.

A marker nobody compares against anything is a claim. Put this in `runtests.jl` and it becomes a
contract:

```julia
using MyPackage, ExperimentalAPI, Test

ExperimentalAPI.test_surface(MyPackage)
```

It fails, naming the symbol, when a public name has no docstring — and also when a mark points at
a name that was never made public, which is the module contradicting itself.

Adopting it on a package that already has a backlog:

```julia
ExperimentalAPI.test_surface(MyPackage; skip = [:legacy_one, :legacy_two])
```

**A stale `skip` entry fails.** A name that has since been documented, declared, or deleted is
reported, so the list can only shrink.

## Install

Not in the General registry yet — install by URL:

```julia
pkg> add https://github.com/QAtlasHub/ExperimentalAPI.jl
```

It is loaded by the package being marked, so it is a normal dependency — but it pulls in nothing
beyond `TOML`, and `Test` only through a package extension.

```toml
[deps]
ExperimentalAPI = "fd2d14cb-3a46-42a9-afd8-e8499236f05e"
```

## Declaring

Attached to a definition, or as a list of names defined elsewhere:

```julia
# the definition site
@experimental(
    "signature will be wrapped once the write-back refactor settles",
    function ingest(config; doc, kwargs...)
        # ...
    end,
)

# names an included file defines
@experimental(
    "reads Test's internal result tree; not dogfooded in CI",
    render_test_report,
    dump_test_report,
    load_test_dump,
)

# with the issue where the shape is being decided
@experimental("export format is a guess until someone consumes it",
    since = v"0.4.0", tracking = "https://github.com/org/Pkg.jl/issues/12",
    registry_entry(x) = x)
```

A docstring and a mark are not exclusive — a name can be documented *and* declared unfinished,
and the two accounts answer different questions.

## Querying

```julia
experimental(MyPackage)              # Vector{Mark}, sorted — the reason travels with the name
isexperimental(MyPackage, :foo)      # the one-bit form
isexperimental(which(fetch, Tuple{Heisenberg,Energy}))   # …and at method granularity
stable(MyPackage)                    # the complement: what you cannot change quietly
audit(MyPackage)                     # the check, as data
```

## Counting, paths and time

Detection is on by default and costs nothing. How *often*, by which paths, and how much of the run
is a separate layer, and it is a call rather than a default for exactly that reason:

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

The emitted statement never changes. Opening a block clears every flag, so the short-circuit fails
and the *write* side — a function call, not an inlined store — does the counting. Counts are
therefore exact and survive inlining, which is what ruled out a sampling profiler: a definition
small enough to be worth marking is small enough to be inlined, and a sampler has no frame left to
attribute to.

`assert_clean(f)` turns the same machinery into a refusal, and `stamp(path, f)` writes it next to
the result it produced, in plain TOML — a year later the package may not resolve, and a provenance
record nobody can open is not one.

## What a caller depends on without naming it

```julia
julia> verdict(reach(analyse, Tuple{Model,Float64}))
:depends
```

Modelled on Lean's `sorry`: a proof that uses one is not a proof, however many layers down it
sits. Julia's call graph is not closed, so the answer is three-valued — `:depends`, `:clean`, and
`:unknown` for a call site that could not be pinned to a method.

That third answer is the point. `h.f(x)` where `h.f::Function`, and `TABLE[i](x)`, really can
reach a marked function while being statically invisible. Reporting `:clean` there is not a weaker
claim, it is a false one.

## Release decisions

Write the covenant down at each release, and compare the next one against it:

```julia
write_snapshot("api.toml", MyPackage)          # at release time, committed
```

```julia
d = compare(read_snapshot("api.toml"), MyPackage)
isbreaking(d) && error("breaking: $(d.removed_stable) removed, $(d.demoted) demoted")
```

Removing a name you declared experimental lands in `removed_experimental` and is **not**
breaking. That is the whole contract: the mark was the notice, given in the source, at the
definition, before the removal. Demoting a settled name to experimental **is** breaking — a
promise withdrawn is a change to what callers were told.

> **Names, not signatures.** `compare` reads name sets. A name present in both snapshots whose
> arguments changed is a breaking change it cannot see. Read the diff as a floor on breakage,
> never as a clearance.

`compare_methods` is the finer instrument: the snapshot also carries `stable_methods` and
`experimental_methods`, keyed by a signature a human can read in a committed file, and that key
carries the keyword **names** a method declares. Keyword *defaults* live in the body and stay
invisible — stated as a constant rather than left to be discovered.

## Why this cannot be a feature of Aqua

A mark is written in `src/`, on the line above the definition, so the package being marked has to
depend on whatever provides `@experimental` at run time. **Aqua is a test-only dependency.** It can
own the check; it structurally cannot own the declaration.

The check here is also not the same set difference. `Docs.undocumented_names` reports every public
name without a docstring — including names re-exported from a dependency, whose prose is somebody
else's job:

```julia
julia> names(Down)                      # `up` and `undoc_up` come from a dependency
4-element Vector{Symbol}:
 :Down, :own_undoc, :undoc_up, :up

julia> Docs.undocumented_names(Down)    # the dependency's gap, reported as yours
3-element Vector{Symbol}:
 :Down, :own_undoc, :undoc_up

julia> audit(Down).unaccounted           # only what this module actually owns
1-element Vector{Symbol}:
 :own_undoc
```

`audit` separates those as `foreign`, and adds `dangling` — a mark on a name that was never made
public, which is the module contradicting itself and needs no reference to be wrong.

## What this is not

| axis | already solved by | this package |
|---|---|---|
| who may call a name | `export`, `public` (1.11) | orthogonal — a name can be public and unfinished |
| a name on its way out | `@deprecate` | opposite direction |
| type stability | DispatchDoctor | unrelated |
| every public name has a docstring | `Docs.undocumented_names` (Base 1.11+), `Aqua.test_undocumented_names` | the same requirement, not a looser one — plus `foreign` and `dangling` |
| generating documentation | Documenter | only ever checks whether prose exists |
| run-time behaviour | — | one short-circuit read in the body; see the table above |
| how often a path ran | `Profile`, `@time` | `record`, opt-in — the default layer knows *whether*, never how often |
| what a caller depends on | — | `reach`, statically, with `:unknown` as an honest third answer |

## What the audit cannot see

Stated up front rather than in a footnote, because a check whose blind spots are undocumented
reads as if it had none:

- **Signatures.** A public name whose arguments change under it is invisible.
- **Prose quality.** A docstring reading `TODO` counts as documented.
- **Methods on other packages' functions** are not in `names(m)`, which is why the audit has a
  second half: `contributed_methods` finds them and `unaccounted_methods` reports the ones with
  neither a docstring nor a mark. For a package whose surface *is* such methods, a clean name
  audit reports nothing while having looked at none of them.
- **Names public only inside an extension**, which is a separate module.
- **Whether a name appears in your guide, README or docs site.** Docstring presence is not
  documentation-page presence, and those two gaps are usually different sets.

## The specification

`test/spec/` is the specification, written as tests before the implementation so it could not
drift from the code — 176 behaviours across ten files, all of them live assertions now.
[`test/spec/README.md`](test/spec/README.md) explains why `@test_broken` was the right register
while they were being filled in, why it is a ratchet now that the count is zero, which negative
control each group has, the two requirements that were **withdrawn** and why one of them could not
be met, and the four defects the exercise found in the shipped code.

## What is not answered

- **Prose quality**, and whether a name appears anywhere but a docstring.
- **Behaviour compatibility.** A signature that stayed put while its meaning moved.
- **Sound analysis past a dynamic call** — that is what `:unknown` is for.
- **Coverage without `--code-coverage`.** `coverage` answers `missing`, never `0.0`: a run that
  measured nothing found nothing, and zero would say the opposite.

## License

MIT
