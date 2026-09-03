# Where the mark has to surface outside this package: docs, Aqua, releases, provenance, CI.
#
# Scope: a mark only `ExperimentalAPI` can read is a private note. Everything here is pure or
# touches a temporary file except the Documenter block, which needs a test dependency this
# package does not have — so nothing in this group is blocked on infrastructure.

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
    # Typed twice, the two drift and the machine-readable one loses.
    @test_broken ExperimentalAPI.docstring_note(Shown, :provisional) isa AbstractString
end

@testset "the rendered note carries the reason, the version and the tracking link" begin
    for needle in ("reference value", "0.2.0", "example.invalid")
        @test_broken occursin(needle, ExperimentalAPI.docstring_note(Shown, :provisional))
    end
end

@testset "a Documenter block can list a module's marks" begin
    # `@autodocs`-style. The only assertion here needing a new test dependency.
    @test_broken ExperimentalAPI.DocumenterExt isa Module
end

@testset "a settled name gets no note" begin
    # Control: rejects a renderer that annotates everything.
    @test_broken ExperimentalAPI.docstring_note(Shown, :settled) === nothing
end

# ── Aqua ─────────────────────────────────────────────────────────────────────────────────────

@testset "the audit composes with Aqua rather than competing" begin
    # Aqua has no third answer; a package must be able to run both.
    @test_broken ExperimentalAPI.aqua_compatible_names(Shown) isa AbstractVector
end

# ── release ──────────────────────────────────────────────────────────────────────────────────
#
# One schema for every case below, mirroring `snapshot`'s two keys, so that "same shape, opposite
# verdict" is true — the fixtures differ only in the variable each one isolates.
function snap(stable, experimental)
    return Dict("stable_methods" => stable, "experimental_methods" => experimental)
end

const MARKED_METHOD = snap(String[], Dict("f(::Int)" => Dict("reason" => "r")))
const PROMOTED_METHOD = snap(["f(::Int)"], Dict())
const SETTLED_METHOD = snap(["f(::Int)"], Dict())
const GONE_METHOD = snap(String[], Dict())
const RESIGNED_METHOD = snap(["f(::Real)"], Dict())

@testset "the method snapshot mirrors the name snapshot's two keys" begin
    # Diverging schemas mean `compare` and `compare_methods` cannot share a snapshot file.
    for d in (MARKED_METHOD, PROMOTED_METHOD, SETTLED_METHOD, GONE_METHOD, RESIGNED_METHOD)
        @test Set(keys(d)) == Set(["stable_methods", "experimental_methods"])
    end
    @test Set(keys(ExperimentalAPI.snapshot(Shown))) ⊇ Set(["stable", "experimental"])
end

@testset "a snapshot records marks at method granularity" begin
    # The schema change method-level marks force — which is why the release layer is itself
    # declared experimental.
    @test_broken haskey(ExperimentalAPI.snapshot(Shown), "experimental_methods")
end

@testset "removing a marked METHOD is not breaking" begin
    @test_broken !ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(MARKED_METHOD, PROMOTED_METHOD)
    )
end

@testset "removing a SETTLED method is breaking" begin
    # Control: same schema, differing only in whether the method was marked.
    @test_broken ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(SETTLED_METHOD, GONE_METHOD)
    )
end

@testset "a signature change to a settled method is reported as breaking" begin
    # The blind spot `compare` admits to in its own docstring.
    @test_broken ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(SETTLED_METHOD, RESIGNED_METHOD)
    )
end

@testset "a keyword-only change is a blind spot here too" begin
    # Keyword arguments live in a separate `kwcall` method, so a signature string cannot see a
    # changed default any more than a name set can. Stated rather than discovered later.
    @test_broken ExperimentalAPI.compare_methods_sees_keywords === true
end

# ── the provenance record next to a result ───────────────────────────────────────────────────

@testset "a result file can carry the experimental dependencies of the run that made it" begin
    # The end state: a figure's directory says which unvalidated code paths produced it.
    @test_broken ExperimentalAPI.stamp(tempname(), () -> Shown.provisional(1)) isa
        AbstractString
end

@testset "the stamp is readable without loading the package that made it" begin
    # Plain TOML or JSON: a year later the package may not resolve. The path goes through
    # `stamp` first, since a bare `tempname()` throws for an unrelated reason.
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
    # Whether `tracking` is required is a per-project decision, and must be expressible.
    @test_broken ExperimentalAPI.test_surface(Shown; require_tracking=true) isa
        ExperimentalAPI.Audit
end

@testset "CI can fail a PR that increases the number of marks" begin
    # The ratchet, in the shape `skip` already has.
    @test_broken ExperimentalAPI.test_surface(Shown; max_marks=0) isa ExperimentalAPI.Audit
end

@testset "a mark older than N releases is reported" begin
    # `since` exists so a mark cannot quietly become permanent. Nothing reads it yet.
    @test_broken ExperimentalAPI.stale_since(Shown, v"0.9.0") isa AbstractVector
end
