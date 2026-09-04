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

# The five questions this answers

| question | the call |
|---|---|
| did **this run** go through unvalidated code? | `entered()` — and the summary at exit says so anyway |
| how often, by which paths, and how much of the run? | `record(f)` |
| does this caller **depend** on something unvalidated, without naming it? | `reach(f, Tuple{…})` |
| what is unfinished here, and which public names are undescribed? | `experimental(M)`, `audit(M)` |
| is dropping this name breaking? | `compare(old_snapshot, M)` — see [`isbreaking`](@ref) |

The first is the reason to have any of it. It is asked *after* a run, *about* the run, by somebody
who is not the author — which is exactly the question a docstring is structurally unable to answer.

# Three layers, and what each costs

  * **Detection** is on always and costs one short-circuit read in the body: measured at `1.03x` on
    one thread and `0.985x` on eight, for 10M calls of a numeric body — see
    [`overhead_when_detecting`](@ref). A flag written once and read thereafter stops dirtying its
    cache line, which a counter (3.76x at eight threads, and losing 40% of its increments to races
    unless atomic) does not.
  * **Recording** ([`record`](@ref)) counts, captures call paths and attributes time. It costs
    something, which is why it is a call and not a default, and each record reports its own
    overhead.
  * **Analysis** ([`reach`](@ref)) is static and answers about code rather than about a run. Its
    answer is three-valued: `:depends`, `:clean`, and `:unknown` for a call site it could not pin
    to a method. Reporting `:unknown` as `:clean` is not a weaker claim, it is a false one.

Only a definition **with a body** carries a flag. A mark written as a name list, or attached to a
struct, a const or a module, is a declaration — queryable, audited and analysable, but not observed
at run time. See [`@experimental`](@ref) for the form-by-form table.

# What this is not

  * **Not visibility.** `public` (Julia 1.11) already decides who may call a name. A name can be
    public and experimental, or public and settled; those are independent axes.
  * **Not deprecation.** `@deprecate` points the other way — a settled name on its way out.
  * **Not type stability.** Unrelated axis, different tooling.
  * **Not a documentation generator.** The prose belongs to the author; [`audit`](@ref) only ever
    checks whether prose exists, never whether it is any good.

# Scope of the check

[`audit`](@ref) compares `names(M)` — exported *and* `public` names — against two independent
accounts: a docstring, and a mark. They are not alternatives; the docstring is owed either way.
Because `names(M)` cannot see a method a package contributed to somebody else's generic, the audit
also reports [`contributed_methods`](@ref) — for a package whose surface *is* such methods, a clean
name audit reports nothing while covering nothing.

See [`compare`](@ref) for the same limit on the release side, and [`compare_methods`](@ref) for the
finer unit.
"""
module ExperimentalAPI

using TOML

export @experimental

# Declaring
public Mark, mark, marks, marks_on, mark_method!, isexperimental, isnamewide
public experimental, experimental_methods, superseded_marks, marks_without_exit

# Observing — what a run went through
public Probe, Entry, entered, marked_modules, probes, detecting, summary_text
public overhead_when_detecting
public Hit, Record, Attribution, TimingBackend, timing_backend
public record, recording, merge_records, attribute, experimental_fraction
public write_record, read_record, assert_clean

# Analysing — what code could reach
public Reach,
    Reached, Unresolved, reach, reach_script, verdict, isclean, combine, dependents

# Checking — the public surface, and the methods no name-level check can see
public Audit, audit, surface, stable, stable_methods, isdocumented, package_extensions
public own_methods, contributed_methods, unaccounted_methods, partition_holds
public extends_base
public aqua_compatible_names, test_surface

# Verifying — how well the tests exercise what is marked
public Verification, verification, coverage, coverage_enabled, unverified, stale_marks
public flush_coverage

# Retiring — when a mark may go
public ready_to_promote, promotable, age, stale_since, exceeds_mark_cap

# Releasing
public Diff, MethodDiff, snapshot, read_snapshot, write_snapshot
public compare, compare_methods, compare_methods_sees_keywords, isbreaking
public stamp, stamp_versions

# Documenting
public docstring_note, marks_markdown

include("mark.jl")       # the Mark record, the per-module registry, and @experimental
include("detect.jl")     # the probe, which marked definitions a run entered, the exit summary
include("query.jl")      # reading a module's marks back out, by name and by method
include("audit.jl")      # the public surface, and the names and methods neither account covers
include("reach.jl")      # what a caller depends on without naming it
include("record.jl")     # the opt-in layer: counts, call paths, and how much of the run
include("verify.jl")     # how well the tests exercise what is marked
include("lifecycle.jl")  # the mark's exit
include("docsnote.jl")   # the mark, in the rendered documentation
include("release.jl")    # a snapshot of the covenant, and what a diff of two of them means

"""
    test_surface(m::Module; skip = Symbol[], require_tracking = false, max_marks = nothing,
                 methods = true, outputlevel = 0) -> Audit

Assert, as a `@testset`, that every public name of `m` has a **docstring**, that every mark applies
to a name that is actually public, and that every method `m` contributed to another module's
generic is accounted for.

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

| keyword | |
|---|---|
| `skip` | names allowed to have no docstring. **A stale entry fails** — a name that has since been documented or removed is reported, so the list can only shrink |
| `require_tracking` | every mark must say where its shape is being decided |
| `max_marks` | the ratchet: a number in the repository that can be lowered and not raised |
| `methods` | run the method-level half, which is the expensive one |

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
