# Where the mark has to show up outside this package.
#
# A mark that only `ExperimentalAPI` can read is a private note. The intent — a reader of a paper,
# a reviewer of a PR, or a user of the docs site learning that a number came from unvalidated
# code — requires the mark to surface in tools nobody configured for it.

using ExperimentalAPI: ExperimentalAPI, @experimental, audit, experimental
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

@testset "a snapshot records marks at method granularity" begin
    # `compare` reads name sets today and says so. Once methods can be marked, the snapshot has
    # to grow — and the schema change is why the release layer is itself declared experimental.
    @test_broken haskey(ExperimentalAPI.snapshot(Shown), "methods")
end

@testset "removing a marked METHOD is not breaking" begin
    # The same contract as for names, at the granularity that matters for a dispatch table.
    @test_broken ExperimentalAPI.compare_methods isa Function
end

@testset "a signature change to a settled method is reported as breaking" begin
    # The blind spot `compare` currently admits to in its own docstring. Method-level marks are
    # what make it addressable at all.
    @test_broken ExperimentalAPI.compare_methods isa Function
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
    path = tempname()
    @test_broken occursin("reference value", read(path, String))
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
