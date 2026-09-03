# Where the mark has to show up outside this package.
#
# A mark that only `ExperimentalAPI` can read is a private note. The intent — a reader of a paper,
# a reviewer of a PR, or a user of the docs site learning that a number came from unvalidated
# code — requires the mark to surface in tools nobody configured for it.
#
# This is the group with the most external dependencies named in it, so: can any of it actually
# run in CI, or is it destined to stay broken because it cannot be otherwise? Checked before
# writing more of it. Of the assertions below, all but one need nothing new — `docstring_note`,
# `aqua_compatible_names`, `compare_methods`, `stale_since` and `test_surface` are pure functions
# over data this package already holds, and `stamp` touches only a temporary file. The single
# exception is `DocumenterExt`, which needs Documenter in the test environment; it is the one row
# here that costs something to turn green, and it is marked as such at its testset.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental
using Test

module Shown

using ExperimentalAPI

public settled, provisional

"Settled and documented."
settled(x) = x

"""
Provisional. Documented, and declared unfinished.
"""
@experimental(
    "the r,s branch has no reference value",
    since = v"0.2.0",
    tracking = "https://example.invalid/issues/9",
    provisional(x) = x
)

end # module Shown

# ── documentation ────────────────────────────────────────────────────────────────────────────

@testset "the docs can render the mark without the author repeating it" begin
    # If the reason has to be typed twice — once in `@experimental`, once in the docstring — the
    # two drift, and the machine-readable one loses.
    @test_broken ExperimentalAPI.docstring_note(Shown, :provisional) isa AbstractString
end

@testset "the rendered note carries the reason, the version and the tracking link" begin
    for needle in ("reference value", "0.2.0", "example.invalid")
        @test_broken occursin(needle, ExperimentalAPI.docstring_note(Shown, :provisional))
    end
end

@testset "a Documenter block can list a module's marks" begin
    # `@autodocs`-style: one block in the manual, always current, never hand-maintained.
    #
    # The only assertion in this file that needs a test dependency this package does not already
    # have (Documenter). Everything else here is pure or touches a temporary file, so this group
    # is not blocked on infrastructure — see the note at the top.
    @test_broken ExperimentalAPI.DocumenterExt isa Module
end

@testset "a settled name gets no note" begin
    # Without this, a renderer that annotates everything passes the tests above.
    @test_broken ExperimentalAPI.docstring_note(Shown, :settled) === nothing
end

# ── Aqua ─────────────────────────────────────────────────────────────────────────────────────

@testset "the audit composes with Aqua rather than competing" begin
    # `Aqua.test_undocumented_names` enforces "every public name has a docstring" and has no
    # third answer. A package should be able to run both without one contradicting the other.
    @test_broken ExperimentalAPI.aqua_compatible_names(Shown) isa AbstractVector
end

# ── release ──────────────────────────────────────────────────────────────────────────────────
#
# One schema for every case below, mirroring `snapshot`'s `"stable"` / `"experimental"` pair. An
# earlier version used `"methods"` in the first testset and `"stable_methods"` in the other two,
# so "same shape, opposite verdict" was false: the fixtures differed in more than the variable
# each one isolates, and no test ever supplied both keys at once.
function snap(stable, experimental)
    return Dict("stable_methods" => stable, "experimental_methods" => experimental)
end

const MARKED_METHOD = snap(String[], Dict("f(::Int)" => Dict("reason" => "r")))
const PROMOTED_METHOD = snap(["f(::Int)"], Dict())
const SETTLED_METHOD = snap(["f(::Int)"], Dict())
const GONE_METHOD = snap(String[], Dict())
const RESIGNED_METHOD = snap(["f(::Real)"], Dict())

@testset "the method snapshot mirrors the name snapshot's two keys" begin
    # If the two schemas diverge, `compare` and `compare_methods` cannot share a snapshot file.
    for d in (MARKED_METHOD, PROMOTED_METHOD, SETTLED_METHOD, GONE_METHOD, RESIGNED_METHOD)
        @test Set(keys(d)) == Set(["stable_methods", "experimental_methods"])
    end
    @test Set(keys(ExperimentalAPI.snapshot(Shown))) ⊇ Set(["stable", "experimental"])
end

@testset "a snapshot records marks at method granularity" begin
    # `compare` reads name sets today and says so. Once methods can be marked, the snapshot has
    # to grow — and the schema change is why the release layer is itself declared experimental.
    @test_broken haskey(ExperimentalAPI.snapshot(Shown), "experimental_methods")
end

@testset "removing a marked METHOD is not breaking" begin
    # The same contract as for names, at the granularity that matters for a dispatch table.
    @test_broken !ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(MARKED_METHOD, PROMOTED_METHOD)
    )
end

@testset "removing a SETTLED method is breaking" begin
    # The negative control: the same schema, differing only in whether the method was marked.
    @test_broken ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(SETTLED_METHOD, GONE_METHOD)
    )
end

@testset "a signature change to a settled method is reported as breaking" begin
    # The blind spot `compare` currently admits to in its own docstring. Method-level marks are
    # what make it addressable at all.
    @test_broken ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(SETTLED_METHOD, RESIGNED_METHOD)
    )
end

@testset "a keyword-only change is a blind spot here too" begin
    # `Tuple`-based signatures have no room for keyword arguments — they live in a separate
    # `kwcall` method — so a change to a default or a kwarg name is invisible to a signature
    # string just as it is to a name set. Stated rather than discovered later.
    @test_broken ExperimentalAPI.compare_methods_sees_keywords === true
end

# ── the provenance record next to a result ───────────────────────────────────────────────────

@testset "a result file can carry the experimental dependencies of the run that made it" begin
    # The end state: a figure's directory contains a record saying which unvalidated code paths
    # produced it. That is the artefact a referee or a future reader needs.
    @test_broken ExperimentalAPI.stamp(tempname(), () -> Shown.provisional(1)) isa
        AbstractString
end

@testset "the stamp is readable without loading the package that made it" begin
    # A year later the package may not resolve. Plain TOML or JSON, not a serialised Julia object.
    # The path has to go through `stamp` first — reading a bare `tempname()` throws SystemError
    # for a reason that has nothing to do with the claim.
    @test_broken occursin(
        "reference value",
        read(ExperimentalAPI.stamp(tempname(), () -> Shown.provisional(1)), String),
    )
end

@testset "a stamped result names the package versions involved" begin
    @test_broken ExperimentalAPI.stamp_versions isa Function
end

# ── CI gates ─────────────────────────────────────────────────────────────────────────────────

@testset "CI can fail a PR that adds a mark without a tracking link" begin
    # `tracking` is what makes a mark actionable rather than a shrug. Whether it is required is a
    # per-project decision, and it has to be expressible.
    @test_broken ExperimentalAPI.test_surface(Shown; require_tracking=true) isa
        ExperimentalAPI.Audit
end

@testset "CI can fail a PR that increases the number of marks" begin
    # The ratchet. `skip` already only shrinks; the mark count should be able to as well.
    @test_broken ExperimentalAPI.test_surface(Shown; max_marks=0) isa ExperimentalAPI.Audit
end

@testset "a mark older than N releases is reported" begin
    # `since` exists so that "experimental" cannot quietly become permanent. Nothing reads it yet.
    @test_broken ExperimentalAPI.stale_since(Shown, v"0.9.0") isa AbstractVector
end
