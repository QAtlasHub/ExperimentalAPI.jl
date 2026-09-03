# Dispatch-level branching: one call site, several methods, only some of them marked.
#
# This is the shape that makes the method-level unit worth having at all. `QAtlas.fetch` has 570
# methods; a caller writes `fetch(model, quantity)` once, and which of the 570 runs — and whether
# that one is trustworthy — depends on the argument types. A verdict about the NAME says nothing.
#
# The dangerous case is a call site the analysis cannot pin to one method. Measured 2026-09-03,
# Julia 1.12.2: for an argument typed `Union{Exact,Numerical}` or an abstract `Kind`, the
# un-optimised IR shows only `(%1)(_2)` and `which(f, T)` **throws** — there is no unique method.
# An implementation that catches that exception and moves on would report `:clean` about a call
# that reaches a marked method at run time half the time. That is the failure this file guards.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental, isexperimental
using Test

module Dispatch

using ExperimentalAPI

public Exact,
    Numerical,
    Kind,
    KA,
    KB,
    energy,
    k,
    only_settled,
    either_way,
    via_abstract,
    via_invoke,
    more_specific

struct Exact end
struct Numerical end

"Closed form; trustworthy."
energy(::Exact) = 1.0
@experimental "no convergence proof below β ≈ 0.1" energy(::Numerical) = 1.0000001

abstract type Kind end
struct KA <: Kind end
struct KB <: Kind end
"Settled."
k(::KA) = 1.0
@experimental "extrapolated, never cross-checked" k(::KB) = 2.0

# The call site can only ever reach the settled method — the negative control.
only_settled(x::Exact) = energy(x)

# The call site can reach EITHER method depending on the run-time type.
either_way(x::Union{Exact,Numerical}) = energy(x)
via_abstract(x::Kind) = k(x)

# `invoke` pins a method regardless of the argument's run-time type.
via_invoke(x::Numerical) = invoke(energy, Tuple{Numerical}, x)

# A more specific unmarked method shadows a marked less specific one.
"Settled, and more specific."
more_specific(::Int) = 0
@experimental "the fallback is a placeholder" more_specific(::Integer) = 1

end # module Dispatch

# ── the fixture really has the shape the file claims ─────────────────────────────────────────

@testset "only some methods behind each name are marked" begin
    marked = Set(mk.name for mk in experimental(Dispatch))
    @test :energy in marked
    @test :k in marked
    @test length(methods(Dispatch.energy)) == 2
    @test length(methods(Dispatch.k)) == 2
    # Today a mark is name-keyed, so it necessarily covers BOTH methods of each name — including
    # the closed-form one that is perfectly trustworthy. That over-claim is the problem.
    @test isexperimental(Dispatch, :energy)
end

@testset "a branching call site has no unique method" begin
    # The measured fact the whole file rests on: `which` cannot answer for these argument types.
    @test which(Dispatch.energy, Tuple{Dispatch.Exact}) isa Method
    @test_throws Exception which(
        Dispatch.energy, Tuple{Union{Dispatch.Exact,Dispatch.Numerical}}
    )
    @test_throws Exception which(Dispatch.k, Tuple{Dispatch.Kind})
end

# ── what the analysis has to say about each shape ────────────────────────────────────────────

@testset "a call site that can only reach settled methods is clean" begin
    # The negative control. Without it, everything below is satisfied by a tool that answers
    # ":depends" for every call site with more than one candidate.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.only_settled, Tuple{Dispatch.Exact})
    ) === :clean
end

@testset "a Union-typed call site that could reach a mark is not clean" begin
    # Half the run-time values take the marked branch. `:clean` here is a false statement, not a
    # conservative one.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(
            Dispatch.either_way, Tuple{Union{Dispatch.Exact,Dispatch.Numerical}}
        ),
    ) !== :clean
end

@testset "an abstract-typed call site that could reach a mark is not clean" begin
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind})
    ) !== :clean
end

@testset "the unresolvable call site is named, not just counted" begin
    # "Somewhere in here I could not tell" is not actionable. The report has to point at the call.
    @test_broken any(
        u -> occursin("k", string(u)),
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind}).unresolved,
    )
end

@testset "which() throwing must not be swallowed into :clean" begin
    # The specific implementation mistake this file exists to prevent: wrapping `which` in a
    # try/catch, skipping the call site, and reporting the remaining graph as clean.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind})
    ) === :unknown
end

# ── dispatch subtleties ──────────────────────────────────────────────────────────────────────

@testset "invoke pins the method it names" begin
    # `invoke(energy, Tuple{Numerical}, x)` reaches the marked method unconditionally, even
    # though the argument's type would have selected it anyway. An analysis that only looks at
    # argument types would miss `invoke` pinning a DIFFERENT method than dispatch would pick.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_invoke, Tuple{Dispatch.Numerical})
    ) === :depends
end

@testset "a more specific unmarked method shadows a marked one" begin
    # `more_specific(::Int)` wins over `more_specific(::Integer)`, so a call with an `Int` never
    # reaches the mark. Reporting `:depends` because *some* method of the name is marked is the
    # name-level over-claim all over again, one level down.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.more_specific, Tuple{Int})
    ) === :clean
    # …and a call that does fall through to the marked fallback is reported.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.more_specific, Tuple{UInt8})
    ) === :depends
end

@testset "a mark on one method does not leak to its siblings at a call site" begin
    # The whole point of going to method granularity: `only_settled` and `either_way` call the
    # same NAME, and must get different verdicts.
    @test_broken ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.only_settled, Tuple{Dispatch.Exact})
    ) !== ExperimentalAPI.verdict(
        ExperimentalAPI.reach(
            Dispatch.either_way, Tuple{Union{Dispatch.Exact,Dispatch.Numerical}}
        ),
    )
end

@testset "the report says WHICH method was reached, not which name" begin
    @test_broken first(
        ExperimentalAPI.reach(Dispatch.either_way, Tuple{Dispatch.Numerical}).reached
    ).method === which(Dispatch.energy, Tuple{Dispatch.Numerical})
end
