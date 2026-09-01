```@meta
CurrentModule = ExperimentalAPI
```

# ExperimentalAPI.jl

`public` says who may call a name. Nothing says whether the name is finished.

So "this will change" lives in a docstring sentence, and no tool reads it. ExperimentalAPI puts
that claim at the definition site, in a form a tool can query — and then turns it into a check
your CI runs:

**every public name is either documented or declared unfinished, and there is no third option.**

```julia
using ExperimentalAPI

@experimental "reads Test's internal result tree; not dogfooded in CI yet" \
function render_test_report(records)
    # ...
end
```

```julia
julia> ExperimentalAPI.audit(MyPackage)
Public surface of MyPackage — 46 names
  documented      45
  experimental     1
  unaccounted      0
```

## Three things, and only the third is a reason to have this

| | |
|---|---|
| a **declaration** | the reason travels with the name, in the source, where the author is — [`@experimental`](@ref) |
| a **query** | a tool asks the module instead of reading prose — [`experimental`](@ref), [`stable`](@ref) |
| a **check** | every public name is accounted for, or the test fails — [`audit`](@ref), [`test_surface`](@ref) |

A marker nobody compares against anything is a claim. A marker something compares against the
public surface is a contract. Everything in the first two rows exists to make the third possible.

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

## What this is not

| axis | already solved by | this package |
|---|---|---|
| who may call a name | `export`, `public` (1.11) | orthogonal |
| a name on its way out | `@deprecate` | opposite direction |
| type stability | DispatchDoctor | unrelated |
| generating documentation | Documenter | only ever checks whether prose exists |
| run-time behaviour | — | calls are untouched |

`@experimental` emits your definition unchanged plus one `push!` at load time. It does not wrap
the call, does not add a method, and does not change dispatch.

## Install

```julia
pkg> add ExperimentalAPI
```

It is loaded by the package being marked, so it is a normal dependency — but it pulls in nothing
beyond `TOML`, and `Test` only through a package extension, so a consumer of your package never
loads `Test` because of this.

## Where to go next

- [Declaring](@ref) — the forms `@experimental` accepts, and what it refuses
- [Checking](@ref) — the audit, its buckets, and what it cannot see
- [Release decisions](@ref) — saying mechanically that a change is not breaking
- [Adopting it](@ref) — turning this on for a package that already has a backlog
