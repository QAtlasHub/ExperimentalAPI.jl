```@meta
CurrentModule = ExperimentalAPI
```

# Analysing

[`entered`](@ref) and [`record`](@ref) say what a run *did*. [`reach`](@ref) says what a caller
*could* do — before running it, and including through code that never names the marked thing.

```julia
julia> r = reach(analyse, Tuple{Model,Float64});

julia> verdict(r)
:depends

julia> r.reached
1-element Vector{ExperimentalAPI.Reached}:
 Reached(MyModel.energy via analyse → sweep → inner → energy)
```

The model is Lean's `sorry`: a proof that uses one is not a proof, however many layers down it
sits. Julia's call graph is not closed, though, so the answer has to be three-valued.

## Three answers, and why the third one exists

| verdict | |
|---|---|
| `:depends` | a marked definition is reachable. Proved, not suspected |
| `:clean` | the whole call graph was resolved and nothing marked is in it |
| `:unknown` | at least one call site could not be pinned to a method |

`:unknown` is the point of the design. Two shapes really can reach a marked function while being
statically invisible:

```julia
struct Holder; f::Function; end
top_field(h::Holder, x) = h.f(x)          # the callee is a value chosen at run time

const TABLE = Function[unstable, solid]
top_table(i, x) = TABLE[i](x)             # …and so is this one
```

Reporting `:clean` there is not a weaker claim, it is a false one. Every unresolved site comes
back as an [`Unresolved`](@ref) carrying the file, the line, why it could not be resolved, and —
when they are visible — the marked methods it could have reached.

There is deliberately no `verdict` **field**: a stored one makes `:clean` with a non-empty
`unresolved` representable, and that is the single state this analysis must never report.
[`verdict`](@ref) derives it, the way [`isbreaking`](@ref) derives its answer from a
[`Diff`](@ref). [`combine`](@ref) folds two verdicts (`:clean` < `:unknown` < `:depends`), which
is what [`reach`](@ref)`(::Module)` does over a module's entry points.

## What it resolves

The walk is over **inferred, un-optimised IR**. Inference runs before inlining, so every call is
still a call and every argument still has a type; `optimize = true` would show `mul_float` and
find nothing.

| call site | |
|---|---|
| a named call, however deep | resolved |
| a function passed as a value | resolved — Julia specialises on `typeof(f)` |
| a `@nospecialize`d callee, called with a concrete function | resolved |
| `invoke(f, Tuple{Integer}, x)` | resolved to the method `invoke` pins, not the one dispatch would pick |
| a marked `const` or `struct` used in the body | `:depends` — a const is not a call site, and reading globals out of the IR is how it is seen |
| a `Union`- or abstract-typed argument whose candidates include a marked method | **`:unknown`** |
| a callee read out of a field or a table | **`:unknown`** |

A call site with several matching methods is not automatically unresolved: every candidate is
walked, and if none of them reaches anything marked the site is resolved after all. That is not a
guess — it is having checked all of them. Without it, `convert(::Type, ::UInt32)` (dozens of
matching methods, none of them anybody's research code) would make every caller that formats a
string `:unknown`.

A more specific unmarked method shadowing a marked one is resolved as what actually runs: an
`Int` goes to `more_specific(::Int)` and is clean, while a `UInt8` falls through to the marked
`::Integer` method and is not.

## Whole modules, and scripts

```julia
r = reach(MyPackage)
verdict(r)                # one answer for the package
r.affected_entries        # …and which public entry points are not clean
```

Function-by-function does not scale to a package, and "something in here is experimental" is not
actionable. Each entry point gets its **own** walk: sharing one visited set would make the second
entry that reaches a mark through an already-walked callee look clean.

[`reach_script`](@ref) is the shape a researcher actually has — a file that produces a figure, not
a package. Note what it costs: the script's top-level `using`, `const` and type definitions are
evaluated in a scratch module, because the analysis has to resolve the names the script uses.

## The exit, read backwards

```julia
dependents(MyPackage, :energy)                  # who reaches it
verdict(reach(MyPackage; ignore = [:energy]))   # what removing the mark would change
```

`ignore` answers "what would removing this mark change?" without removing it. [`dependents`](@ref)
is propagation read the other way: a mark gets deleted because somebody looked at the definition,
not at who reaches it.

## What it is not

  * **Not a run.** It says what *could* be reached; [`record`](@ref) says what was. A path this
    reports is not necessarily taken.
  * **Not sound past a dynamic call.** That is what `:unknown` is for, and why
    [`isclean`](@ref) answers `false` for it — the predicate means "may I rely on this", and the
    honest non-answer is not a yes.
  * **Not free.** It runs inference over the call graph. `maxdepth` and `maxcandidates` bound it,
    and hitting either bound is reported as `:unknown`, never as `:clean`.
