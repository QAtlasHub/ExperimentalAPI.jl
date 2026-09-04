"""
    ExperimentalAPI

Say, at the definition site, that a name is **not settled yet** — and find out, without asking,
when a run went through it.

`public` decides who may call a name. Whether the name is *finished* is the orthogonal question,
and the place it is usually answered is a sentence in a docstring that no tool reads. That matters
most where it is least visible: a long numerical run finishes, hands back a number, and nothing in
the result says which of the code paths behind it had never been validated.

```julia
using ExperimentalAPI

@experimental "convergence not established below β ≈ 0.1" energy(m::Model) = m.β * correction(m)
```

The mark is three things, and the first is the reason to have it:

  * an **observation** — [`entered`](@ref) reports the marked definitions this run actually went
    through, and a summary says so at process exit whether or not anyone asked;
  * a **declaration** — the reason travels with the name, in the source, where the author is;
  * a **check** — [`audit`](@ref) reports every public name with no docstring, marked or not, so
    "every public name is described" becomes a test that fails.

# What it costs

One short-circuit read in the body, and a write on the first call only: measured at 1.03x on one
thread and 0.985x on eight, for 10M calls of a numeric body. A flag written once and read
thereafter stops dirtying the cache line, which a counter (3.76x at eight threads, and losing 40%
of its increments to races unless atomic) does not. Counting, call sites and paths are a separate
layer that is not built yet.

Only a definition **with a body** carries a flag. A mark written as a name list, or attached to a
struct, a const or a module, is a declaration — queryable, audited, but not observed at run time.
See [`@experimental`](@ref) for the form-by-form table.

# The three questions this answers

| question | the call |
|---|---|
| did this run go through unvalidated code? | `entered()` — and the summary at exit says so anyway |
| what is unfinished here? | `experimental(M)` |
| which public names are undescribed? | `audit(M).undocumented` — should be empty |
| is dropping this name breaking? | `compare(old_snapshot, M)` — see [`isbreaking`](@ref) |

# What this is not

  * **Not visibility.** `public` (Julia 1.11) already decides who may call a name. A name can be
    public and experimental, or public and settled; those are independent axes.
  * **Not deprecation.** `@deprecate` points the other way — a settled name on its way out.
  * **Not type stability.** Unrelated axis, different tooling.
  * **Not instrumentation.** The body gains one short-circuit read, nothing more: no counter, no
    logging call, no allocation. What it can answer is "was this entered at all", never how often.
  * **Not a documentation generator.** The prose belongs to the author; this only ever checks
    whether prose exists.

# Scope of the check

[`audit`](@ref) compares `names(M)` — exported *and* `public` names — against two independent
accounts: a docstring, and a mark. They are not alternatives; the docstring is owed either way.
It sees **names**, not signatures and not prose quality. A public name with a docstring reading
"TODO" is accounted for; a settled name whose method signature changed under it is invisible here.
See [`compare`](@ref) for the same limit on the release side.
"""
module ExperimentalAPI

using TOML

export @experimental

public Mark, Audit, Diff
public experimental, isexperimental, mark, isdocumented
public Entry, entered, marked_modules, detecting, summary_text
public surface, stable, audit
public snapshot, read_snapshot, write_snapshot, compare, isbreaking
public test_surface

include("mark.jl")      # the Mark record, the per-module registry, and @experimental
include("detect.jl")    # which marked definitions a run entered, and the summary at exit
include("query.jl")     # reading a module's marks back out
include("audit.jl")     # the public surface, and the names neither account covers
include("release.jl")   # a snapshot of the covenant, and what a diff of two of them means

"""
    test_surface(m::Module; skip = Symbol[], outputlevel::Int = 0) -> Audit

Assert, as a `@testset`, that every public name of `m` has a **docstring** — and that every mark
applies to a name that is actually public.

A mark is not an alternative to prose. `@experimental` records that a shape is unsettled, which is
never a reason to say nothing about what the name does, so a marked-but-undocumented name fails
this test exactly as an unmarked one does. There is no switch to turn that off; `skip` is the only
escape, and it is per-name, visible, and can only shrink.

Available once `Test` is loaded (it lives in a package extension, so `ExperimentalAPI` itself
never pulls `Test` into a runtime dependency). Put it in `runtests.jl`:

```julia
using MyPackage, ExperimentalAPI, Test

ExperimentalAPI.test_surface(MyPackage)
```

`skip` is for adopting this on a package that already has a backlog: the listed names are allowed
to have no docstring. **A stale entry fails the test** — a name in `skip` that has since been
documented or removed is reported, so the list can only shrink.

Returns the [`Audit`](@ref) on the normal return path whether the testset passed or not.
`outputlevel ≥ 1` also prints it.
"""
function test_surface end

# Armed at load time rather than on first mark: the hook has to be in place before any of the
# marked package's code runs, and `atexit` is the only place a summary can see a whole run.
function __init__()
    detecting() && atexit(_summarise)
    return nothing
end

end # module
