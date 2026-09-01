# Declaring

## The two forms

[`@experimental`](@ref) takes a reason — always first, never optional — and then either **one
definition** or **a list of names**.

```julia
# attached to the definition: the mark and the thing it describes cannot drift apart
@experimental "signature will be wrapped once the write-back refactor settles" \
function ingest(config; doc, kwargs...)
    # ...
end

# a list, for names an included file defines
@experimental "reads Test's internal result tree; not dogfooded in CI" \
    render_test_report dump_test_report load_test_dump
```

The attached form is preferred where it fits, for the same reason a docstring goes above its
function: a declaration two hundred lines from what it describes stops being true without anyone
noticing.

## The reason is the payload

Why a name is not settled is knowledge only the author has. A reader can see that a signature is
odd; they cannot see that it is odd *because* a refactor upstream has not landed. So the reason
is required, and the mark carries it everywhere the name goes:

```julia
julia> mark(Archeion, :ingest)
Archeion.ingest — experimental
  reason:   signature will be wrapped once the write-back refactor settles
  since:    v0.1.4
  tracking: https://github.com/QAtlasHub/Archeion.jl/issues/12
  declared: /…/Archeion.jl/src/ingest.jl:153
```

`since` and `tracking` are optional and go between the reason and the subject:

```julia
@experimental("export format is a guess until someone consumes it",
    since = v"0.4.0",
    tracking = "https://github.com/org/Pkg.jl/issues/12",
    registry_entry(x) = x)
```

`tracking` is what turns a mark into something a reader can act on rather than merely be warned
by: it names where the shape is being decided, so a downstream author can go and argue for the
shape they need.

## What it attaches to

`function`, short-form `f(x) = …`, `struct`, `mutable struct`, `abstract type`,
`primitive type`, `macro` (recorded as `Symbol("@name")`), `const`, and plain assignment.

Anything else is **refused with a message naming the alternative**, never guessed at:

```julia
julia> @experimental "why" Base.sum(x::Int) = x
ERROR: @experimental: `Base.sum(x::Int)` defines a name owned by another module,
which is not part of this module's public surface
```

The refused cases and why:

| | |
|---|---|
| `module M … end` | Julia requires it as a direct top-level statement, so it cannot be wrapped — use the name-list form |
| `Base.foo(x) = …` | adds a method to a name this module does not own; it is not on your surface |
| `@somemacro …` | the macro cannot know which name the expansion defines — name it explicitly |

Guessing in any of these cases would produce a mark on the wrong symbol, which is worse than no
mark: `audit` would then report it as `dangling` and the author would be debugging this package
instead of their own.

## Docstrings still work

A name can be documented **and** declared unfinished. The two accounts answer different
questions, and nothing forces a choice between them:

```julia
"""
    ingest(config; doc, kwargs...)

Ingest `doc` into the registry described by `config`.
"""
@experimental "signature will be wrapped once the write-back refactor settles" \
function ingest(config; doc, kwargs...)
    # ...
end
```

## Marking is not making public

A mark says nothing about visibility. A name still has to be `export`ed or declared `public` to
be part of the surface, and a mark on a name that is neither promises nothing to anyone —
[`audit`](@ref) reports it as `dangling`:

```julia
module M
using ExperimentalAPI
@experimental "not settled" helper(x) = x   # never exported, never public
end
```

```julia
julia> audit(M).dangling
1-element Vector{Symbol}:
 :helper
```

That check needs no reference to be right. The module is disagreeing with itself.

## Top level only

The mark is stored in a `const` binding in the enclosing module, so `@experimental` belongs where
`export` and `public` go. Inside a function body it will fail with Julia's own error about `const`
in local scope.

## Where the marks live

In the marked module, as `M.__EXPERIMENTAL_API_MARKS__` — a plain `Vector{Mark}` you can look at.
Not in a table inside ExperimentalAPI, because a table there would be written while *your* package
is being precompiled and would not be part of the cache image your users load. It is the same
reason Julia keeps docstrings in a per-module `Docs.META`.
