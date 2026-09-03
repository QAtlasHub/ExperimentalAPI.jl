```@meta
CurrentModule = ExperimentalAPI
```

# ExperimentalAPI.jl

`public` says who may call a name. Nothing says whether the name is *finished* — and nothing tells
you, after a twelve-hour run, that the number you are about to publish came out of code its author
had not validated.

`@experimental` is that mark, written at the definition site where the author is, and readable by
a machine so the answer arrives without anyone remembering to ask for it.

```julia
using ExperimentalAPI

@experimental "convergence not established below β ≈ 0.1" energy(m::Model) = m.β * correction(m)
```

```console
$ julia sweep.jl
… your output …
┌ ExperimentalAPI: this run entered 1 experimental definition
│   MyModel.energy — convergence not established below β ≈ 0.1
└ set ENV["EXPERIMENTALAPI_SUMMARY"] = "0" before `using` to silence this
```

Nobody asked for that summary. It is on by default, it carries the **reason** rather than just the
symbol, and a marked definition the run never entered is *absent* — not reported with a count of
zero. The same answer is available programmatically through [`entered`](@ref).

## Three things, and the first is the reason to have this

| | |
|---|---|
| an **observation** | which marked definitions the run went through — [`entered`](@ref), and the summary at exit |
| a **declaration** | the reason travels with the name, in the source, where the author is — [`@experimental`](@ref) |
| a **check** | every public name is accounted for, or the test fails — [`audit`](@ref), [`test_surface`](@ref) |

A docstring can carry the second row. Nothing a human writes can carry the first: the question is
not "is this name experimental" but "did *this run* go through one", and it has to be answered
after the run, about the run.

## What it costs

One short-circuit read in the body, and a write on the first call:

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
exit rather than a warning at the call.

Only a definition **with a body** carries a flag; see [`@experimental`](@ref) for the
form-by-form table. Counting, call sites and paths are a separate, opt-in layer that is not built
yet.

## Why this is a separate axis

Visibility was solved by the language: Julia 1.11's `public` keyword decides who is *allowed* to
call a name, and `names(m)` reports the result. Stability is the orthogonal question — whether
the name is *finished* — and it has no keyword, no query, and no check.

The two are genuinely independent. A name can be:

- public and settled — the normal case, and the one a docstring describes;
- public and unfinished — real, common, and currently expressible only as prose;
- private and settled, or private and unfinished — not this package's business either way,
  because nobody was promised anything.

The second row is what [`@experimental`](@ref) is for.

## Why this cannot be a feature of Aqua

A mark is written in `src/`, on the line above the definition, so the marked package depends on
whatever provides [`@experimental`](@ref) at run time. **Aqua is a test-only dependency.** It can
own the check; it structurally cannot own the declaration.

The check is not the same set difference either. `Docs.undocumented_names` reports every public
name without a docstring, including names re-exported from a dependency whose prose is somebody
else's job. [`audit`](@ref) files those as `foreign`, and adds `dangling` — a mark on a name that
was never made public, which is the module contradicting itself.

## What this is not

| axis | already solved by | this package |
|---|---|---|
| who may call a name | `export`, `public` (1.11) | orthogonal |
| a name on its way out | `@deprecate` | opposite direction |
| type stability | DispatchDoctor | unrelated |
| every public name has a docstring | `Docs.undocumented_names`, `Aqua.test_undocumented_names` | the same requirement, not a looser one — plus `foreign` and `dangling` |
| generating documentation | Documenter | only ever checks whether prose exists |
| run-time behaviour | — | one short-circuit read in the body — see the table above |
| how often a path ran | `Profile`, `@time` | not answered: the default layer knows *whether*, never how often |

`@experimental` adds one statement to the body and nothing else. It does not add a method, does
not change dispatch, and never allocates or logs.

## Install

Not in the General registry yet — install by URL:

```julia
pkg> add https://github.com/QAtlasHub/ExperimentalAPI.jl
```

It is loaded by the package being marked, so it is a normal dependency — but it pulls in nothing
beyond `TOML`, and `Test` only through a package extension, so a consumer of your package never
loads `Test` because of this.

## Where to go next

- [Declaring](@ref) — the forms `@experimental` accepts, and what it refuses
- [Checking](@ref) — the audit, its buckets, and what it cannot see
- [Release decisions](@ref) — saying mechanically that a change is not breaking
- [Adopting it](@ref) — turning this on for a package that already has a backlog
