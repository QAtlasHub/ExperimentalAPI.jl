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

# exact — trustworthy, and documented at the signature it applies to
"""
    fetch_value(::Ising, ::Energy)

Closed form. Exact for every lattice size.
"""
UpstreamGeneric.fetch_value(::Ising, ::Energy) = -2.0

# numerically delicate — this is the one that carries a mark
@experimental(
    "extrapolated from a finite-size sweep; no reference value",
    since = v"0.1.0",
    tracking = "https://example.invalid/issues/7",
    UpstreamGeneric.fetch_value(::Heisenberg, ::Energy) = -1.7724538509055159,
)

# a whole family that is provisional, and says nothing at all — the finding
UpstreamGeneric.fetch_value(::Ising, ::Susceptibility) = 0.0
UpstreamGeneric.fetch_value(::Heisenberg, ::Susceptibility) = 0.0

end # module Downstream

@testset "the fixture really is the foreign-generic shape" begin
    @test parentmodule(UpstreamGeneric.fetch_value) === UpstreamGeneric
    @test length(methods(UpstreamGeneric.fetch_value)) == 5
    @test count(m -> m.module === Downstream, methods(UpstreamGeneric.fetch_value)) == 4
    @test :fetch_value ∉ ExperimentalAPI.surface(Downstream)   # invisible to names()
end

@testset "a qualified definition is accepted, and names a method rather than a surface" begin
    # This used to be a refusal, pinned so the change would be visible when it happened. It has:
    # extending another package's generic is the normal Julia idiom, and a mark that cannot
    # attach there cannot describe the surface that matters.
    @test begin
        @eval module MarkedForeign
        using ExperimentalAPI
        using ..UpstreamGeneric
        struct Probe end
        @experimental "provisional" UpstreamGeneric.fetch_value(::Probe, ::Probe) = 0
        end
        !isempty(ExperimentalAPI.experimental_methods(Main.MarkedForeign))
    end
    # It carries a signature, which is what makes it a claim about one method…
    mk = only(ExperimentalAPI.experimental_methods(Main.MarkedForeign))
    @test mk.sig !== nothing
    # …and it is not a promise about `MarkedForeign`'s own surface, so it cannot dangle.
    @test isempty(ExperimentalAPI.audit(Main.MarkedForeign; methods=false).dangling)
end

@testset "marking one foreign method leaves the siblings alone" begin
    exact = which(UpstreamGeneric.fetch_value, Tuple{Downstream.Ising,Downstream.Energy})
    delicate = which(
        UpstreamGeneric.fetch_value, Tuple{Downstream.Heisenberg,Downstream.Energy}
    )
    @test exact !== delicate
    @test ExperimentalAPI.isexperimental(delicate)
    @test !ExperimentalAPI.isexperimental(exact)
    # The reason travels with the method, which is the whole point of putting it there.
    @test occursin("extrapolated", ExperimentalAPI.mark(delicate).reason)
    @test ExperimentalAPI.mark(delicate).tracking == "https://example.invalid/issues/7"
end

@testset "the mark is stored in the module that WROTE the method" begin
    # Not in `UpstreamGeneric`: a package cannot carry claims its dependents invented, and the
    # mark must survive it being reloaded. `all(pred, [])` is `true`, so non-emptiness is part of
    # the claim.
    @test !isempty(ExperimentalAPI.experimental_methods(Downstream)) &&
        all(mk -> mk.mod === Downstream, ExperimentalAPI.experimental_methods(Downstream))
end

@testset "the ownership query and the cross-module search are different verbs" begin
    # "what this module owns" and "what anyone has marked on this generic" are both wanted, and
    # one name for both means the reader cannot tell which they got.
    @test ExperimentalAPI.marks_on isa Function
    # The two really do answer differently: `Downstream` owns one mark on `fetch_value`, and the
    # search over the generic finds that one plus whatever `MarkedForeign` contributed.
    @test length(ExperimentalAPI.experimental_methods(Downstream)) == 1
    @test length(ExperimentalAPI.marks_on(UpstreamGeneric.fetch_value)) >= 2
    @test all(mk -> mk.mod === Downstream, ExperimentalAPI.experimental_methods(Downstream))
end

@testset "asking the generic finds marks contributed by every package" begin
    @test !isempty(ExperimentalAPI.experimental(UpstreamGeneric.fetch_value))
end

@testset "audit reports foreign methods this module owns" begin
    # `foreign` means "bound elsewhere, not our problem". A method we wrote is the opposite.
    a = audit(Downstream)
    @test hasproperty(a, :contributed_methods)
    @test length(a.contributed_methods) == 4
    # Control: the name-level half cannot see any of this, which is why the method half exists —
    # `fetch_value` is not in `names(Downstream)` and never will be.
    @test :fetch_value ∉ a.surface
    @test isempty(a.dangling)
end

@testset "a contributed method with neither docstring nor mark is a finding" begin
    unacc = ExperimentalAPI.unaccounted_methods(Downstream)
    @test !isempty(unacc)
    # Exactly the two that say nothing: the documented one and the marked one are accounted for.
    @test length(unacc) == 2
    @test all(mm -> mm.sig.parameters[3] === Downstream.Susceptibility, unacc)
end

@testset "a docstring on a specific signature counts" begin
    # Docstrings are keyed by signature, so "documented" is answerable per method.
    documented = which(
        UpstreamGeneric.fetch_value, Tuple{Downstream.Ising,Downstream.Energy}
    )
    silent = which(
        UpstreamGeneric.fetch_value, Tuple{Downstream.Ising,Downstream.Susceptibility}
    )
    @test ExperimentalAPI.isdocumented(documented) isa Bool
    @test ExperimentalAPI.isdocumented(documented)
    # Control: the generic itself is documented upstream, and that must not count for every
    # method behind it — otherwise one docstring in `UpstreamGeneric` accounts for all 570.
    @test !ExperimentalAPI.isdocumented(silent)
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
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(caller, Tuple{Float64})) ===
        :depends
    # Control: the same call through the exact method is clean, so the verdict is the MARK being
    # found and not the generic being foreign.
    clean(x) = UpstreamGeneric.fetch_value(Downstream.Ising(), Downstream.Energy()) + x
    @test ExperimentalAPI.verdict(ExperimentalAPI.reach(clean, Tuple{Float64})) === :clean
end

@testset "a mark on a method of a function defined in Base is possible" begin
    # "Base is off limits" would exclude a large part of every package's surface.
    @test begin
        @eval module MarkedBase
        using ExperimentalAPI
        struct Widget end
        @experimental "printing format not settled" Base.show(io::IO, ::Widget) =
            print(io, "W")
        end
        !isempty(ExperimentalAPI.experimental_methods(Main.MarkedBase))
    end
    # Control: `Base.show` is not made experimental for anybody else.
    @test !ExperimentalAPI.isexperimental(Base, :show)
    @test !ExperimentalAPI.isexperimental(which(show, Tuple{IO,Int}))
end

@testset "it stays refused when the mark cannot say WHICH method" begin
    # A bare qualified name with no signature would mark every method of `Base.show` in the
    # world. Guessing is worse than refusing.
    @test_throws LoadError @eval module RefusedBareForeign
    using ExperimentalAPI
    @experimental "why" Base.show
    end
end
