# Marking a method on somebody else's function.
#
# This is the QAtlas case and the current implementation refuses it outright.
#
#     QAtlas.fetch is AbstractQAtlas.fetch — 570 methods (measured 2026-09-03; QAtlas is not a
#     dependency here, so nothing in this suite re-derives that number and it can go stale).
#     `:fetch` is not QAtlas's own binding, so `audit` files it under `foreign` and says nothing
#     about any of the 570.
#
# A package that extends another package's generic is the normal Julia idiom, not an edge case.
# If the mark cannot attach there, it cannot describe the surface that matters.

using ExperimentalAPI: ExperimentalAPI, @experimental, audit, experimental, isexperimental
using Test

module UpstreamGeneric
"The generic every downstream package extends."
fetch_value(model, quantity) = error("no method for $(typeof(model)), $(typeof(quantity))")
public fetch_value
end

module Downstream

using ExperimentalAPI
using ..UpstreamGeneric: UpstreamGeneric, fetch_value

public Ising, Heisenberg, Energy, Susceptibility

struct Ising end
struct Heisenberg end
struct Energy end
struct Susceptibility end

# exact — trustworthy
UpstreamGeneric.fetch_value(::Ising, ::Energy) = -2.0

# numerically delicate — this is the one that should carry a mark
UpstreamGeneric.fetch_value(::Heisenberg, ::Energy) = -1.7724538509055159

# a whole family that is provisional
UpstreamGeneric.fetch_value(::Ising, ::Susceptibility) = 0.0
UpstreamGeneric.fetch_value(::Heisenberg, ::Susceptibility) = 0.0

end # module Downstream

@testset "the fixture really is the foreign-generic shape" begin
    @test parentmodule(UpstreamGeneric.fetch_value) === UpstreamGeneric
    @test length(methods(UpstreamGeneric.fetch_value)) == 5
    @test count(m -> m.module === Downstream, methods(UpstreamGeneric.fetch_value)) == 4
    @test :fetch_value ∉ ExperimentalAPI.surface(Downstream)   # invisible to names()
end

@testset "the macro currently refuses a qualified definition" begin
    # Today's behaviour, pinned so the change is visible when it happens.
    @test_throws LoadError @eval module RefusedForeign
    using ExperimentalAPI
    using ..UpstreamGeneric
    @experimental "why" UpstreamGeneric.fetch_value(::Int, ::Int) = 0
    end
end

@testset "a method on a foreign generic can be marked" begin
    # Ends in a Bool, and checks WHAT was marked: `@eval module … end` returns a Module, so a bare
    # `@test_broken @eval module …` reports "Expression evaluated to non-Boolean" on success
    # instead of the "Unexpected Pass" this directory relies on.
    @test_broken begin
        @eval module MarkedForeign
        using ExperimentalAPI
        using ..UpstreamGeneric
        struct Probe end
        @experimental "provisional" UpstreamGeneric.fetch_value(::Probe, ::Probe) = 0
        end
        !isempty(ExperimentalAPI.experimental_methods(Main.MarkedForeign))
    end
end

@testset "marking one foreign method leaves the siblings alone" begin
    exact = which(UpstreamGeneric.fetch_value, Tuple{Downstream.Ising,Downstream.Energy})
    delicate = which(
        UpstreamGeneric.fetch_value, Tuple{Downstream.Heisenberg,Downstream.Energy}
    )
    @test exact !== delicate
    # The fixture cannot carry `@experimental` on these methods: the macro refuses a qualified
    # definition today and the whole module would fail to load. So the test MARKS IT ITSELF
    # through the future API. Asserting `isexperimental(delicate)` without ever marking it would
    # stay Broken forever, even once method-level marking works perfectly.
    @test_broken begin
        ExperimentalAPI.mark_method!(delicate, "numerically delicate")
        ExperimentalAPI.isexperimental(delicate) && !ExperimentalAPI.isexperimental(exact)
    end
end

@testset "the mark is stored in the module that WROTE the method" begin
    # Not in UpstreamGeneric. A package cannot be made to carry claims its dependents invented, and the
    # mark has to survive UpstreamGeneric being reloaded or updated.
    #
    # `all(pred, [])` is `true` in Julia, so an `experimental_methods` stub that always returns an
    # empty vector would satisfy a bare `all(...)`. Non-emptiness has to be part of the claim.
    @test_broken !isempty(ExperimentalAPI.experimental_methods(Downstream)) && all(
        mk -> mk.mod === Downstream, ExperimentalAPI.experimental_methods(Downstream)
    )
end

@testset "asking the generic finds marks contributed by every package" begin
    # The question a user asks is about `fetch_value`, not about which package happened to define
    # the method they will dispatch to.
    @test_broken !isempty(ExperimentalAPI.experimental(UpstreamGeneric.fetch_value))
end

@testset "audit reports foreign methods this module owns" begin
    # `foreign` today means "a name bound elsewhere, not our problem". A method WE wrote on
    # someone else's generic is the opposite: our problem, invisible under the current rule.
    a = audit(Downstream)
    @test_broken hasproperty(a, :contributed_methods)
    @test_broken length(a.contributed_methods) == 4
end

@testset "a contributed method with neither docstring nor mark is a finding" begin
    # The whole point of the audit, applied to the surface that actually matters for QAtlas.
    @test_broken !isempty(ExperimentalAPI.unaccounted_methods(Downstream))
end

@testset "a docstring on a specific signature counts" begin
    # Julia stores docstrings keyed by signature, so "documented" is answerable per method — the
    # audit does not have to fall back to the name.
    @test_broken ExperimentalAPI.isdocumented(
        which(UpstreamGeneric.fetch_value, Tuple{Downstream.Ising,Downstream.Energy})
    ) isa Bool
end

@testset "marking a method does not make the foreign NAME experimental" begin
    # Otherwise one downstream package could label another package's whole generic unfinished.
    @test !isexperimental(UpstreamGeneric, :fetch_value)
end

@testset "propagation crosses the package boundary" begin
    # A caller in a third package that reaches a marked method in Downstream, through UpstreamGeneric's
    # generic, must be reported. This is the QAtlas → analysis-script path.
    caller(x) =
        UpstreamGeneric.fetch_value(Downstream.Heisenberg(), Downstream.Energy()) + x
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(caller, Tuple{Float64})) ===
        :depends
end

@testset "a mark on a method of a function defined in Base is possible" begin
    # `Base.show`, `Base.length`, `Base.copy` — QAtlas defines methods on all three. The rule
    # cannot be "Base is off limits" without excluding a large part of every package's surface.
    @test_broken begin
        @eval module MarkedBase
        using ExperimentalAPI
        struct Widget end
        @experimental "printing format not settled" Base.show(io::IO, ::Widget) =
            print(io, "W")
        end
        !isempty(ExperimentalAPI.experimental_methods(Main.MarkedBase))
    end
end

@testset "it stays refused when the mark cannot say WHICH method" begin
    # `@experimental "why" Base.show` — a bare qualified NAME, no signature. Marking every method
    # of `Base.show` in the world is never what anyone means, and guessing is worse than refusing.
    @test_throws LoadError @eval module RefusedBareForeign
    using ExperimentalAPI
    @experimental "why" Base.show
    end
end
