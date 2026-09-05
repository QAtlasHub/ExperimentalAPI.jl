# Where the mark has to surface outside this package: docs, Aqua, releases, provenance, CI.
#
# Scope: a mark only `ExperimentalAPI` can read is a private note. Everything here is pure or
# touches a temporary file except the Documenter block, which needs a test dependency this
# package does not have — so nothing in this group is blocked on infrastructure.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental
using Documenter: Documenter
using Documenter: MarkdownAST
using TOML: TOML
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
    @test ExperimentalAPI.docstring_note(Shown, :provisional) isa AbstractString
end

@testset "the rendered note carries the reason, the version and the tracking link" begin
    for needle in ("reference value", "0.2.0", "example.invalid")
        @testset "$needle" begin
            @test occursin(needle, ExperimentalAPI.docstring_note(Shown, :provisional))
        end
    end
end

@testset "a Documenter block can list a module's marks" begin
    # `@autodocs`-style: a docs page writes ```` ```@experimental ```` and names a module. Reached
    # through `Base.get_extension` rather than as a field of the package — an extension is a
    # separate module and is not a binding in its parent.
    ext = Base.get_extension(ExperimentalAPI, :ExperimentalAPIDocumenterExt)
    @test ext isa Module
    @test ext in ExperimentalAPI.package_extensions(ExperimentalAPI)
    # The expander is registered against Documenter's pipeline, not merely defined.
    @test isdefined(ext, :ExperimentalBlocks)
    @test Documenter.Selectors.order(ext.ExperimentalBlocks) isa Real
    @test Documenter.Selectors.matcher(
        ext.ExperimentalBlocks,
        MarkdownAST.Node(MarkdownAST.CodeBlock("@experimental", "Shown")),
        nothing,
        nothing,
    )
    # Control: an ordinary code block is not claimed by it.
    @test !Documenter.Selectors.matcher(
        ext.ExperimentalBlocks,
        MarkdownAST.Node(MarkdownAST.CodeBlock("julia", "1 + 1")),
        nothing,
        nothing,
    )
end

@testset "the rendered list is markdown, and says what it found" begin
    md = ExperimentalAPI.marks_markdown(Shown)
    @test occursin("provisional", md)
    @test occursin("reference value", md)
    # Control: a module with nothing marked renders a sentence rather than an empty heading, so
    # "this page is empty" and "the build found nothing" do not look identical.
    @eval module NothingMarked
    "Settled."
    f(x) = x
    public f
    end
    @test occursin(
        "no experimental names", ExperimentalAPI.marks_markdown(Main.NothingMarked)
    )
end

@testset "a settled name gets no note" begin
    # Control: rejects a renderer that annotates everything.
    @test ExperimentalAPI.docstring_note(Shown, :settled) === nothing
end

# ── Aqua ─────────────────────────────────────────────────────────────────────────────────────

@testset "the audit composes with Aqua rather than competing" begin
    # Aqua has no third answer; a package must be able to run both. What this reports is the
    # DIFFERENCE — the names Aqua flags and `audit` accounts for — so a project can see exactly
    # what it would have to argue about.
    @test ExperimentalAPI.aqua_compatible_names(Shown) isa AbstractVector
    # `Shown` documents everything it marks, so the two tools agree and the difference is empty.
    @test isempty(ExperimentalAPI.aqua_compatible_names(Shown))
    # Control: a marked-but-undocumented name is exactly where they part company.
    @eval module Disagreeing
    using ExperimentalAPI
    public marked_only
    @experimental "no prose yet" marked_only(x) = x
    end
    @test ExperimentalAPI.aqua_compatible_names(Main.Disagreeing) == [:marked_only]
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
    snap = ExperimentalAPI.snapshot(Shown)
    @test haskey(snap, "experimental_methods")
    @test haskey(snap, "stable_methods")
    # The key is a signature a human can read in a committed file, and it carries the argument
    # types — not `Tuple{typeof(provisional), Any}`, which moves when a module is renamed.
    @test collect(keys(snap["experimental_methods"])) == ["provisional(::Any)"]
    @test "settled(::Any)" in snap["stable_methods"]
end

@testset "removing a marked METHOD is not breaking" begin
    @test !ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(MARKED_METHOD, PROMOTED_METHOD)
    )
end

@testset "removing a SETTLED method is breaking" begin
    # Control: same schema, differing only in whether the method was marked.
    @test ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(SETTLED_METHOD, GONE_METHOD)
    )
end

@testset "a signature change to a settled method is reported as breaking" begin
    # The blind spot `compare` admits to in its own docstring.
    @test ExperimentalAPI.isbreaking(
        ExperimentalAPI.compare_methods(SETTLED_METHOD, RESIGNED_METHOD)
    )
end

@testset "keyword NAMES are seen, and keyword DEFAULTS are not" begin
    # Stated rather than discovered later, and stated in both directions: the signature key
    # carries the keyword names a method declares, so adding or renaming one moves the key —
    # while a changed default lives in the body and moves nothing.
    @test ExperimentalAPI.compare_methods_sees_keywords === true
    @eval module Kw
    using ExperimentalAPI
    public f
    "Documented."
    f(x; tol=1e-8) = x * tol
    end
    key = only(
        filter(
            k -> startswith(k, "f("), ExperimentalAPI.snapshot(Main.Kw)["stable_methods"]
        ),
    )
    @test occursin("tol", key)
    # …and the blind spot, named: the default is not in the key, so changing it moves nothing.
    @test !occursin("1e-8", key)
    @test !occursin("1.0e-8", key)
end

# ── the provenance record next to a result ───────────────────────────────────────────────────

@testset "a result file can carry the experimental dependencies of the run that made it" begin
    # The end state: a figure's directory says which unvalidated code paths produced it.
    @test ExperimentalAPI.stamp(tempname(), () -> Shown.provisional(1)) isa AbstractString
end

@testset "the stamp is readable without loading the package that made it" begin
    # Plain TOML: a year later the package may not resolve. The path goes through `stamp` first,
    # since a bare `tempname()` throws for an unrelated reason.
    text = read(ExperimentalAPI.stamp(tempname(), () -> Shown.provisional(1)), String)
    @test occursin("reference value", text)
    @test occursin("provisional", text)
    # Parseable by something that is not this package.
    @test TOML.parse(text) isa AbstractDict
    # Control: a run that touched nothing marked writes a stamp that says so, rather than none.
    clean = read(ExperimentalAPI.stamp(tempname(), () -> Shown.settled(1)), String)
    @test !occursin("reference value", clean)
    @test isempty(TOML.parse(clean)["experimental"])
end

@testset "a stamped result names the package versions involved" begin
    @test ExperimentalAPI.stamp_versions isa Function
    v = ExperimentalAPI.stamp_versions()
    @test v isa AbstractDict
    @test haskey(v, "julia")
    # `energy` being experimental in v0.3 says nothing about v0.9, so the stamp carries versions.
    text = read(ExperimentalAPI.stamp(tempname(), () -> Shown.provisional(1)), String)
    @test occursin("[versions]", text)
end

# ── CI gates ─────────────────────────────────────────────────────────────────────────────────

# A gate is only a gate if it can be shown to fire, and `test_surface` reports through a
# `@testset` — so the failing direction has to be run under a test set that records instead of
# propagating. Two lines of `AbstractTestSet` is the whole cost of checking that.
struct Collect <: Test.AbstractTestSet
    results::Vector{Any}
    Collect(::AbstractString) = new(Any[])
end
Test.record(ts::Collect, res) = (push!(ts.results, res); res)
# A nested `@testset` that does not name a type inherits the enclosing one, so every set inside
# `test_surface` is a `Collect` too — and one that did not hand itself up would drop everything
# it recorded on the floor. Measured by an empty `results` where three passes and a failure had
# just gone by.
function Test.finish(ts::Collect)
    Test.get_testset_depth() > 0 && Test.record(Test.get_testset(), ts)
    return ts
end
"""
    gate_failed(f) -> Bool

Run `f` under a test set that records instead of propagating, and say whether anything in it
failed. This is how a gate is shown to fire without the failure it is supposed to produce
reaching the suite that is checking for it.
"""
function gate_failed(f)
    ts = @testset Collect "probe" begin
        f()
    end
    return any(r -> r isa Test.Fail || r isa Test.Error, _flatten(ts))
end

_flatten(ts::Collect) = reduce(vcat, (_flatten(r) for r in ts.results); init=Any[])
function _flatten(ts::Test.DefaultTestSet)
    return reduce(vcat, (_flatten(r) for r in ts.results); init=Any[])
end
_flatten(r) = Any[r]

@testset "CI can fail a PR that adds a mark without a tracking link" begin
    # Whether `tracking` is required is a per-project decision, and must be expressible.
    @test ExperimentalAPI.test_surface(Shown; require_tracking=true) isa
        ExperimentalAPI.Audit
    # `Shown`'s one mark has a link, so the gate passes…
    @test !gate_failed(() -> ExperimentalAPI.test_surface(Shown; require_tracking=true))
    # …and it fires on a mark that has none, which is what makes it a gate.
    @eval module Untracked
    using ExperimentalAPI
    public f
    "Documented."
    @experimental "shape undecided" f(x) = x
    end
    @test gate_failed(
        () -> ExperimentalAPI.test_surface(Main.Untracked; require_tracking=true)
    )
    # Control: without the keyword the same module passes, so the failure is the gate and not
    # something else about the fixture.
    @test !gate_failed(() -> ExperimentalAPI.test_surface(Main.Untracked))
end

@testset "CI can fail a PR that increases the number of marks" begin
    # The ratchet, in the shape `skip` already has.
    @test ExperimentalAPI.test_surface(Shown; max_marks=1) isa ExperimentalAPI.Audit
    @test !gate_failed(() -> ExperimentalAPI.test_surface(Shown; max_marks=1))
    @test gate_failed(() -> ExperimentalAPI.test_surface(Shown; max_marks=0))
end

@testset "a mark older than N releases is reported" begin
    # `since` exists so a mark cannot quietly become permanent.
    @test ExperimentalAPI.stale_since(Shown, v"0.9.0") isa AbstractVector
    @test :provisional in [mk.name for mk in ExperimentalAPI.stale_since(Shown, v"0.9.0")]
    # Control: seen from the release it was made in, nothing is stale.
    @test isempty(ExperimentalAPI.stale_since(Shown, v"0.2.0"))
    @test ExperimentalAPI.age(Shown, :provisional, v"0.9.0") == 7
end
