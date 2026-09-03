# What can carry a mark.
#
# The current implementation marks a NAME. The intent is to mark a definition — and for
# `QAtlas.fetch`, which has 570 methods behind one name (see `test_spec_foreign.jl`), the name is the wrong unit: a docstring
# on `fetch` cannot say which dispatch path returns a number you can trust.
#
# So this file covers both: what works today (plain `@test`) and what the unit has to become
# (`@test_broken`).

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

# The shape the method-level unit has to reach: one name, several dispatch paths, and only one
# of them is in doubt. This is `QAtlas.fetch` in miniature.
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
    # Without this, an `experimental()` that leaks every declared name — rather than only the
    # marked ones — passes every assertion above.
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
# `Declared.energy` has three methods. Marking the name marks all three, which is the granularity
# problem: the exact-solution path is trustworthy and the numerical one is not.

@testset "marking a name is the wrong unit when the name has many methods" begin
    @test length(methods(Declared.energy)) == 3
    # Today the only available statement is about the name, so it necessarily over-claims.
    @test !isexperimental(Declared, :energy)   # not marked at all yet — see below
end

@testset "a single dispatch path can be marked" begin
    m = which(Declared.energy, Tuple{Declared.Numerical,Float64})
    @test_broken ExperimentalAPI.mark(m) isa Mark
    @test_broken ExperimentalAPI.isexperimental(m)
end

@testset "marking one method leaves its siblings alone" begin
    numerical = which(Declared.energy, Tuple{Declared.Numerical,Float64})
    exact = which(Declared.energy, Tuple{Declared.Exact,Float64})
    rational = which(Declared.energy, Tuple{Declared.Numerical,Rational})
    @test numerical !== exact !== rational
    @test_broken ExperimentalAPI.isexperimental(numerical)
    @test_broken !ExperimentalAPI.isexperimental(exact)
    @test_broken !ExperimentalAPI.isexperimental(rational)
end

@testset "a method mark survives precompilation" begin
    # The name-keyed registry already survives (test/test_precompile.jl). `Method` objects are
    # part of the defining module's image too, but that is a separate claim and needs its own
    # fixture package before it can be asserted.
    @test_broken ExperimentalAPI.experimental_methods isa Function
end

@testset "a method mark is queryable from a call site" begin
    # The question a downstream test actually asks, before trusting a reference value.
    @test_broken ExperimentalAPI.isexperimental(
        which(Declared.energy, Tuple{Declared.Numerical,Float64})
    )
end

# ── extensions ───────────────────────────────────────────────────────────────────────────────
#
# A package extension is a separate module. Names it makes public are part of the package's
# surface from a user's point of view, and are invisible to `names(Package)`.

@testset "a mark inside a package extension is reachable from the parent" begin
    ext = Base.get_extension(ExperimentalAPI, :ExperimentalAPITestExt)
    @test ext !== nothing
    # `!isempty(...)` would NOT do: ExperimentalAPI marks six of its own names in `src/release.jl`
    # (dogfooding), so a keyword that is accepted and then completely ignored would satisfy it.
    # The claim is that a mark whose home is the EXTENSION comes back.
    @test isempty(ExperimentalAPI.experimental(ext))          # today the extension declares none
    @test_broken any(
        mk -> mk.mod === ext, ExperimentalAPI.experimental(ExperimentalAPI; extensions=true)
    )
end

@testset "every new Audit field keeps the partition invariant" begin
    # Three files each pin a new `Audit` field with `hasproperty` alone — `:extensions` here,
    # `:undocumented` in the docstring spec, `:contributed_methods` in the foreign spec — written
    # without cross-referencing each other. `hasproperty` is blind to whether the property the
    # type exists for still holds once three fields are bolted on from three directions.
    a = ExperimentalAPI.audit(ExperimentalAPI)
    @test sort(
        vcat(a.foreign, a.documented, a.unaccounted, setdiff(a.declared, a.documented))
    ) == a.surface
    @test_broken ExperimentalAPI.partition_holds(a) === true
end

@testset "auditing a package does not silently ignore its extensions" begin
    a = ExperimentalAPI.audit(ExperimentalAPI)
    # Today `audit` looks at one module. Whether an extension's surface is in scope has to be a
    # stated answer rather than an omission.
    @test_broken hasproperty(a, :extensions)
end
