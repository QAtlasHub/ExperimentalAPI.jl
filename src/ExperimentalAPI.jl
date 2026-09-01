"""
    ExperimentalAPI

Say, at the definition site, that a public name is **not settled yet** — and turn that into a
check something runs.

Visibility is already a language feature: `export` and `public` decide who is *allowed* to call a
name. Stability is the orthogonal question — whether the name is *finished* — and today the only
place to answer it is a sentence in a docstring that no tool reads and no CI job verifies.

```julia
using ExperimentalAPI

@experimental "reads Test's internal result tree; not dogfooded in CI yet" \
function render_test_report(records)
    # ...
end
```

That mark is three things at once, and only the third is the reason to have it:

  * a **declaration** — the reason travels with the name, in the source, where the author is;
  * a **query** — [`experimental`](@ref) hands a tool the list, [`stable`](@ref) hands it the
    complement;
  * a **check** — [`audit`](@ref) reports every public name that is *neither* documented *nor*
    declared, so "document it or admit it is unfinished" becomes a test that fails.

The check is the point. A marker that is only ever written is a claim; a marker something
compares against the public surface is a contract.

# The three questions this answers

| question | the call |
|---|---|
| what is unfinished here? | `experimental(M)` |
| what does this module owe nobody an explanation for? | `audit(M).unaccounted` — should be empty |
| is dropping this name breaking? | `compare(old_snapshot, M)` — see [`isbreaking`](@ref) |

# What this is not

  * **Not visibility.** `public` (Julia 1.11) already decides who may call a name. A name can be
    public and experimental, or public and settled; those are independent axes.
  * **Not deprecation.** `@deprecate` points the other way — a settled name on its way out.
  * **Not type stability.** Unrelated axis, different tooling.
  * **Not a runtime wrapper.** `@experimental` emits the definition unchanged plus one `push!` at
    load time. Calls are untouched.
  * **Not a documentation generator.** The prose belongs to the author; this only ever checks
    whether prose exists.

# Scope of the check

[`audit`](@ref) compares `names(M)` — exported *and* `public` names — against two accounts:
a docstring, or a mark. It sees **names**, not signatures and not prose quality. A public name
with a docstring reading "TODO" is accounted for; a settled name whose method signature changed
under it is invisible here. See [`compare`](@ref) for the same limit on the release side.
"""
module ExperimentalAPI

using TOML

export @experimental

public Mark, Audit, Diff
public experimental, isexperimental, mark, isdocumented
public surface, stable, audit
public snapshot, read_snapshot, write_snapshot, compare, isbreaking
public test_surface

include("mark.jl")      # the Mark record, the per-module registry, and @experimental
include("query.jl")     # reading a module's marks back out
include("audit.jl")     # the public surface, and the names neither account covers
include("release.jl")   # a snapshot of the covenant, and what a diff of two of them means

"""
    test_surface(m::Module; skip = Symbol[], outputlevel::Int = 0) -> Audit

Assert, as a `@testset`, that every public name of `m` is either documented or declared
[`@experimental`](@ref) — and that every mark applies to a name that is actually public.

Available once `Test` is loaded (it lives in a package extension, so `ExperimentalAPI` itself
never pulls `Test` into a runtime dependency). Put it in `runtests.jl`:

```julia
using MyPackage, ExperimentalAPI, Test

ExperimentalAPI.test_surface(MyPackage)
```

`skip` is for adopting this on a package that already has a backlog: the listed names are
allowed to be unaccounted for. **A stale entry fails the test** — a name in `skip` that has since
been documented, declared, or removed is reported, so the list can only shrink.

Returns the [`Audit`](@ref) on the normal return path whether the testset passed or not.
`outputlevel ≥ 1` also prints it.
"""
function test_surface end

end # module
