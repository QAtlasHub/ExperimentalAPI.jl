# The audit: every public name lands in exactly one bucket, and the bucket it lands in is the one
# a reader would put it in.

using ExperimentalAPI: audit, isdocumented, stable, surface

module Upstream
"A dependency's name, documented by the dependency."
up_thing(x) = x
end

module Audited

using ExperimentalAPI
using ..Upstream: up_thing

export exported_documented, up_thing
public public_documented, public_experimental, public_silent, Silent, @silent_macro

"Exported and documented."
exported_documented(x) = x

"Public and documented."
public_documented(x) = x

@experimental "not settled" public_experimental(x) = x

# No docstring, no mark: the finding.
public_silent(x) = x
struct Silent end
macro silent_macro(x)
    return esc(x)
end

# Marked, but never made public — a mark that promises nothing to anyone.
@experimental "marked but hidden" hidden_marked(x) = x

# A documented name that is ALSO marked: allowed, and counted as documented.
"Documented and still moving."
@experimental "shape still moving" both(x) = x
public both

# Not public at all, and not marked: invisible to the audit by design.
internal_thing(x) = x

end # module Audited

@testset "surface is exactly the exported and public names" begin
    @test surface(Audited) == sort([
        :exported_documented,
        :up_thing,
        :public_documented,
        :public_experimental,
        :public_silent,
        :Silent,
        Symbol("@silent_macro"),
        :both,
    ])
    @test :internal_thing ∉ surface(Audited)
    @test :hidden_marked ∉ surface(Audited)
    @test nameof(Audited) ∉ surface(Audited)
end

@testset "buckets" begin
    a = audit(Audited)
    @test a.mod === Audited
    @test a.unaccounted == sort([:public_silent, :Silent, Symbol("@silent_macro")])
    @test a.declared == sort([:public_experimental, :both])
    @test a.documented == sort([:exported_documented, :public_documented, :both])
    @test a.foreign == [:up_thing]
    @test a.dangling == [:hidden_marked]
end

@testset "every public name is accounted for exactly once" begin
    a = audit(Audited)
    # `declared` deliberately overlaps `documented` (a name may be both); the partition claim is
    # about the other three plus the union.
    @test sort(
        vcat(a.foreign, a.documented, a.unaccounted, setdiff(a.declared, a.documented))
    ) == a.surface
    @test isempty(intersect(a.unaccounted, a.declared))
    @test isempty(intersect(a.unaccounted, a.documented))
    @test isempty(intersect(a.foreign, a.unaccounted))
end

@testset "stable is the surface minus the marks" begin
    @test stable(Audited) == setdiff(surface(Audited), [:public_experimental, :both])
    @test eltype(stable(Audited)) === Symbol
end

@testset "isdocumented reads prose, not marks" begin
    # This pins `Base.Docs.hasdoc`, which is not public Base API — if it ever stops separating
    # these two cases, this test is where that surfaces rather than in a consumer's CI.
    @test isdocumented(Audited, :exported_documented)
    @test isdocumented(Audited, :public_documented)
    @test !isdocumented(Audited, :public_silent)
    @test !isdocumented(Audited, :public_experimental)
    # Re-exported: `hasdoc` follows the binding to Upstream, so the name counts as documented
    # here without Audited repeating the prose. `audit` still files it under `foreign`.
    @test isdocumented(Audited, :up_thing)
    @test :up_thing ∈ audit(Audited).foreign
    @test :up_thing ∉ audit(Audited).documented
end

module Submoduled
using ExperimentalAPI
module Inner
    "An inner name, documented here."
    inner_thing(x) = x
end
using .Inner: inner_thing
public inner_thing
end

@testset "a submodule's name is still this package's to account for" begin
    a = audit(Submoduled)
    @test isempty(a.foreign)              # Inner is ours; a dependency would not be
    @test a.documented == [:inner_thing]
end

@testset "a module that never opted in audits cleanly" begin
    a = audit(Upstream)
    @test isempty(a.surface)
    @test isempty(a.unaccounted)
    @test isempty(a.dangling)
end

@testset "show prints the findings, all of them" begin
    s = sprint(show, MIME"text/plain"(), audit(Audited); context=:displaysize => (24, 200))
    @test occursin("unaccounted", s)
    for n in audit(Audited).unaccounted
        @test occursin(string(n), s)
    end
    @test occursin("dangling", s)
    @test occursin("hidden_marked", s)
    @test occursin("Audit(", sprint(show, audit(Audited)))
end
