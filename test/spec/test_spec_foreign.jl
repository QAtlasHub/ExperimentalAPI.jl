# Marking a method on somebody else's generic — the `QAtlas.fetch` case, refused outright today.
#
# Scope: `audit` files a name bound elsewhere under `foreign` and says nothing about the methods
# we contributed to it. Extending another package's generic is the normal Julia idiom, so a mark
# that cannot attach there cannot describe the surface that matters.

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
    # Pinned so the change is visible when it happens.
    @test_throws LoadError @eval module RefusedForeign
    using ExperimentalAPI
    using ..UpstreamGeneric
    @experimental "why" UpstreamGeneric.fetch_value(::Int, ::Int) = 0
    end
end

@testset "a method on a foreign generic can be marked" begin
    # Ends in a Bool and checks what was marked — see `README.md` on `@eval module`.
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
    # The fixture cannot carry `@experimental` here — a qualified definition is refused today
    # and the module would not load — so the test marks it through the future API. Otherwise this
    # stays Broken even once method-level marking works.
    @test_broken begin
        ExperimentalAPI.mark_method!(delicate, "numerically delicate")
        ExperimentalAPI.isexperimental(delicate) && !ExperimentalAPI.isexperimental(exact)
    end
end

@testset "the mark is stored in the module that WROTE the method" begin
    # Not in `UpstreamGeneric`: a package cannot carry claims its dependents invented, and the
    # mark must survive it being reloaded. `all(pred, [])` is `true`, so non-emptiness is part of
    # the claim.
    @test_broken !isempty(ExperimentalAPI.experimental_methods(Downstream)) && all(
        mk -> mk.mod === Downstream, ExperimentalAPI.experimental_methods(Downstream)
    )
end

@testset "the ownership query and the cross-module search are different verbs" begin
    # "what this module owns" and "what anyone has marked on this generic" are both wanted, and
    # one name for both means the reader cannot tell which they got.
    @test_broken ExperimentalAPI.marks_on isa Function
end

@testset "asking the generic finds marks contributed by every package" begin
    @test_broken !isempty(ExperimentalAPI.experimental(UpstreamGeneric.fetch_value))
end

@testset "audit reports foreign methods this module owns" begin
    # `foreign` means "bound elsewhere, not our problem". A method we wrote is the opposite.
    a = audit(Downstream)
    @test_broken hasproperty(a, :contributed_methods)
    @test_broken length(a.contributed_methods) == 4
end

@testset "a contributed method with neither docstring nor mark is a finding" begin
    @test_broken !isempty(ExperimentalAPI.unaccounted_methods(Downstream))
end

@testset "a docstring on a specific signature counts" begin
    # Docstrings are keyed by signature, so "documented" is answerable per method.
    @test_broken ExperimentalAPI.isdocumented(
        which(UpstreamGeneric.fetch_value, Tuple{Downstream.Ising,Downstream.Energy})
    ) isa Bool
end

@testset "marking a method does not make the foreign NAME experimental" begin
    # Control: one dependent must not be able to label a whole generic unfinished.
    @test !isexperimental(UpstreamGeneric, :fetch_value)
end

@testset "propagation crosses the package boundary" begin
    # The QAtlas -> analysis-script path: a third package reaching a marked method through the
    # upstream generic.
    caller(x) =
        UpstreamGeneric.fetch_value(Downstream.Heisenberg(), Downstream.Energy()) + x
    @test_broken ExperimentalAPI.verdict(ExperimentalAPI.reach(caller, Tuple{Float64})) ===
        :depends
end

@testset "a mark on a method of a function defined in Base is possible" begin
    # "Base is off limits" would exclude a large part of every package's surface.
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
    # A bare qualified name with no signature would mark every method of `Base.show` in the
    # world. Guessing is worse than refusing.
    @test_throws LoadError @eval module RefusedBareForeign
    using ExperimentalAPI
    @experimental "why" Base.show
    end
end
