# What can carry a mark: function, method, struct, const, module, macro, extension.
#
# Scope: both units. A mark names something, and — when it attached to a definition — also records
# the signature it attached to, so the same declaration answers `audit`'s question about the name
# and `reach`'s question about the method.

using ExperimentalAPI: ExperimentalAPI, @experimental, Mark, experimental, isexperimental
using Test

module Declared

using ExperimentalAPI

export documented_fn
public plain_fn,
    short_fn,
    Struct,
    MutStruct,
    AbstractKind,
    PrimKind,
    CONSTANT,
    ASSIGNED,
    Sub,
    @marked_macro,
    listed_a,
    listed_b,
    energy

@experimental "long form" function plain_fn(x)
    return x
end
@experimental "short form" short_fn(x) = x
@experimental "struct" struct Struct
    v::Int
end
@experimental "mutable struct" mutable struct MutStruct
    v::Int
end
@experimental "abstract type" abstract type AbstractKind end
@experimental "primitive type" primitive type PrimKind 8 end
@experimental "const" const CONSTANT = 1
@experimental "plain assignment" ASSIGNED = 2
@experimental "macro" macro marked_macro(x)
    return esc(x)
end

module Sub end
@experimental "a module can only be marked by name" Sub

listed_a(x) = x
listed_b(x) = x
@experimental "declared, not attached" listed_a listed_b

"Documented and settled."
documented_fn(x) = x

# One name, several dispatch paths, only one in doubt — `QAtlas.fetch` in miniature.
struct Exact end
struct Numerical end
energy(::Exact, β::Float64) = β
energy(::Numerical, β::Float64) = β + 1e-12
energy(::Numerical, β::Rational) = β

end # module Declared

@testset "every definition form can be marked" begin
    got = Dict(mk.name => mk for mk in experimental(Declared))
    for (name, reason) in (
        :plain_fn => "long form",
        :short_fn => "short form",
        :Struct => "struct",
        :MutStruct => "mutable struct",
        :AbstractKind => "abstract type",
        :PrimKind => "primitive type",
        :CONSTANT => "const",
        :ASSIGNED => "plain assignment",
        Symbol("@marked_macro") => "macro",
        :Sub => "a module can only be marked by name",
        :listed_a => "declared, not attached",
        :listed_b => "declared, not attached",
    )
        @testset "$name" begin
            @test haskey(got, name)
            @test got[name].reason == reason
        end
    end
end

@testset "nothing else is reported as marked" begin
    # Control: rejects an `experimental()` that leaks every declared name.
    got = Set(mk.name for mk in experimental(Declared))
    @test length(got) == 12
    for unmarked in (:documented_fn, :energy, :Exact, :Numerical)
        @testset "$unmarked is not reported" begin
            @test unmarked ∉ got
        end
    end
end

@testset "the reason travels with every one of them" begin
    for mk in experimental(Declared)
        @test !isempty(strip(mk.reason))
        @test mk.mod === Declared
        @test mk.line > 0
        @test String(mk.file) == @__FILE__
    end
end

# ── the method-level unit ────────────────────────────────────────────────────────────────────
#
# `Declared.energy` has three methods; marking the name marks all three, including the exact one.

@testset "the name is the wrong unit when the name has many methods" begin
    @test length(methods(Declared.energy)) == 3
    # Nothing is marked here yet, so the three assertions below start from a clean fixture.
    @test !isexperimental(Declared, :energy)
end

@testset "a single dispatch path can be marked" begin
    m = which(Declared.energy, Tuple{Declared.Numerical,Float64})
    @test ExperimentalAPI.mark_method!(m, "extrapolated below β ≈ 0.1") isa Mark
    @test ExperimentalAPI.mark(m) isa Mark
    @test ExperimentalAPI.isexperimental(m)
    # The record knows the signature it is about, which is what makes it narrower than the name.
    @test ExperimentalAPI.mark(m).sig === m.sig
end

@testset "marking one method leaves its siblings alone" begin
    numerical = which(Declared.energy, Tuple{Declared.Numerical,Float64})
    exact = which(Declared.energy, Tuple{Declared.Exact,Float64})
    rational = which(Declared.energy, Tuple{Declared.Numerical,Rational})
    @test numerical !== exact !== rational
    @test ExperimentalAPI.isexperimental(numerical)
    @test !ExperimentalAPI.isexperimental(exact)
    @test !ExperimentalAPI.isexperimental(rational)
end

@testset "a method mark is stored where a name mark is, and comes back with one" begin
    # Scope: the name-keyed registry already survives precompilation (`test/test_precompile.jl`),
    # and a method mark is a record in the same vector — a signature is serialisable where a
    # `Method` object would not have been.
    @test ExperimentalAPI.experimental_methods isa Function
    ms = ExperimentalAPI.experimental_methods(Declared)
    @test :energy in [mk.name for mk in ms]
    @test all(mk -> mk.mod === Declared, ms)
    @test ExperimentalAPI.mark(Declared, :energy) !== nothing
end

@testset "a method mark is queryable from a call site" begin
    @test ExperimentalAPI.isexperimental(
        which(Declared.energy, Tuple{Declared.Numerical,Float64})
    )
end

@testset "…but the marked NAME is still a promise, because a sibling is unmarked" begin
    # The direction a method-level mark must not leak: one unvalidated dispatch path is not a
    # licence to remove `energy`. `stable` keeps a name until every method behind it is marked.
    @test :energy in ExperimentalAPI.stable(Declared)
    @test :short_fn ∉ ExperimentalAPI.stable(Declared)   # one method, and it is marked
end

# ── extensions ───────────────────────────────────────────────────────────────────────────────
#
# An extension is a separate module: its public names are part of the surface a user sees, and
# invisible to `names(Package)`.

@testset "a mark inside a package extension is reachable from the parent" begin
    ext = Base.get_extension(ExperimentalAPI, :ExperimentalAPITestExt)
    @test ext !== nothing
    # Not `!isempty(...)`: this package marks several of its own names, so an ignored keyword
    # would satisfy that. The claim is that a mark whose home is the EXTENSION comes back.
    @test !isempty(ExperimentalAPI.experimental(ext))
    @test any(
        mk -> mk.mod === ext, ExperimentalAPI.experimental(ExperimentalAPI; extensions=true)
    )
    # Control: without the keyword it does not, so the keyword is doing the work.
    @test !any(mk -> mk.mod === ext, ExperimentalAPI.experimental(ExperimentalAPI))
end

@testset "every new Audit field keeps the partition invariant" begin
    # Three files each add an `Audit` field behind `hasproperty` alone. `hasproperty` cannot see
    # whether the partition still holds once all three land.
    a = ExperimentalAPI.audit(ExperimentalAPI)
    @test sort(
        vcat(a.foreign, a.documented, a.unaccounted, setdiff(a.declared, a.documented))
    ) == a.surface
    @test ExperimentalAPI.partition_holds(a) === true
end

@testset "auditing a package does not silently ignore its extensions" begin
    a = ExperimentalAPI.audit(ExperimentalAPI)
    # Stated rather than silent: an extension is a separate module, so it is REPORTED and audited
    # in its own right rather than folded in — an extension that is not loaded is not missing, it
    # is inapplicable.
    @test hasproperty(a, :extensions)
    @test Base.get_extension(ExperimentalAPI, :ExperimentalAPITestExt) in a.extensions
    @test ExperimentalAPI.audit(
        only(filter(x -> nameof(x) === :ExperimentalAPITestExt, a.extensions))
    ) isa ExperimentalAPI.Audit
end
