# One call site, several methods, only some of them marked.
#
# Scope: the call site the analysis cannot pin to one method. For a `Union`-typed or abstract
# argument `which(f, T)` throws, and an implementation that catches that and moves on reports
# `:clean` about a call that reaches a marked method half the time. That is the failure guarded
# here.

using ExperimentalAPI: ExperimentalAPI, @experimental, experimental, isexperimental, mark
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
    more_specific,
    imperative,
    pair,
    via_pair_clean,
    via_pair_marked

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

# Control: can only ever reach the settled method.
only_settled(x::Exact) = energy(x)

# The call site can reach EITHER method depending on the run-time type.
either_way(x::Union{Exact,Numerical}) = energy(x)
via_abstract(x::Kind) = k(x)

# `invoke` pins a method dispatch would NOT pick: an `Int` goes to the unmarked `::Int` normally.
# Pinning `Tuple{Numerical}` instead would be satisfied by an analysis that ignores `invoke`.
via_invoke(x::Int) = invoke(more_specific, Tuple{Integer}, x)

# Two arguments, as in `fetch(model, quantity)`: the marked combination is not reachable from
# either argument alone.
pair(::Exact, ::Exact) = 0.0
pair(::Exact, ::Numerical) = 1.0
@experimental "only this combination is unvalidated" pair(::Numerical, ::Numerical) = 2.0
pair(::Numerical, ::Exact) = 3.0
via_pair_clean(a::Exact, b::Exact) = pair(a, b)
via_pair_marked(a::Numerical, b::Numerical) = pair(a, b)

# A more specific unmarked method shadows a marked less specific one.
"Settled, and more specific."
more_specific(::Int) = 0
@experimental "the fallback is a placeholder" more_specific(::Integer) = 1

# Definitions the macro cannot attach to: `@eval` in a loop is the shape a table-driven package
# has, and it is why `mark_method!` exists at all.
for T in (:Exact, :Numerical)
    @eval imperative(::$T) = 1.0
end

end # module Dispatch

# ── the fixture really has the shape the file claims ─────────────────────────────────────────

@testset "only some methods behind each name are marked" begin
    marked = Set(mk.name for mk in experimental(Dispatch))
    @test :energy in marked
    @test :k in marked
    @test length(methods(Dispatch.energy)) == 2
    @test length(methods(Dispatch.k)) == 2
    # A name-keyed mark covers both methods, including the closed-form one. That is the problem.
    @test isexperimental(Dispatch, :energy)
end

@testset "the specificity premise the file rests on is true" begin
    # The premise every verdict below rests on, and which nothing else would notice.
    @test which(Dispatch.more_specific, Tuple{Int}).sig ===
        Tuple{typeof(Dispatch.more_specific),Int}
    @test Dispatch.more_specific(5) == 0            # the UNMARKED, more specific method
    @test Dispatch.more_specific(UInt8(5)) == 1     # falls through to the MARKED fallback
    @test Dispatch.via_invoke(5) == 1               # invoke reaches what dispatch would not pick
end

@testset "a branching call site has no unique method" begin
    # `@test_throws Exception` would be satisfied by a typo raising `UndefVarError`, so pin the
    # diagnosis rather than the failure.
    @test which(Dispatch.energy, Tuple{Dispatch.Exact}) isa Method
    for (f, T) in (
        (Dispatch.energy, Tuple{Union{Dispatch.Exact,Dispatch.Numerical}}),
        (Dispatch.k, Tuple{Dispatch.Kind}),
    )
        @testset "$T" begin
            e = try
                which(f, T)
                nothing
            catch err
                err
            end
            @test e isa ErrorException
            @test occursin("ambiguous", sprint(showerror, e))
        end
    end
end

@testset "the attached mark names the name AND the signature it attached to" begin
    # Both statements are true of one record, and they answer different questions. `audit` asks
    # about the name — has the author said anything about `energy`? `reach` asks about the
    # method — is THIS dispatch path the unvalidated one?
    @test isexperimental(Dispatch, :energy)
    @test mark(Dispatch, :energy).name === :energy
    @test mark(Dispatch, :energy).sig === Tuple{typeof(Dispatch.energy),Dispatch.Numerical}
    @test ExperimentalAPI.isexperimental(which(Dispatch.energy, Tuple{Dispatch.Numerical}))
    # Control: the sibling method is not marked, so the name-level answer is the wider one.
    @test !ExperimentalAPI.isexperimental(which(Dispatch.energy, Tuple{Dispatch.Exact}))
end

@testset "a method the macro could not reach can be marked imperatively" begin
    # The route for a definition produced by another package's macro, or generated in a loop.
    # The mark lands in the module that WROTE the method, exactly where the macro would put it.
    @test ExperimentalAPI.mark_method! isa Function
    m = which(Dispatch.imperative, Tuple{Dispatch.Numerical})
    @test !ExperimentalAPI.isexperimental(m)              # …before
    mk = ExperimentalAPI.mark_method!(m, "generated in a loop; shape not settled")
    @test mk isa ExperimentalAPI.Mark
    @test mk.mod === Dispatch
    @test mk.sig === m.sig
    @test ExperimentalAPI.isexperimental(m)               # …and after
    # Control: the sibling produced by the same loop is untouched.
    @test !ExperimentalAPI.isexperimental(which(Dispatch.imperative, Tuple{Dispatch.Exact}))
end

# ── what the analysis has to say about each shape ────────────────────────────────────────────

@testset "a call site that can only reach settled methods is clean" begin
    # Control: rejects a tool answering `:depends` for every multi-candidate call site.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.only_settled, Tuple{Dispatch.Exact})
    ) === :clean
end

@testset "a Union-typed call site that could reach a mark is not clean" begin
    # Half the run-time values take the marked branch, so `:clean` is false, not conservative.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(
            Dispatch.either_way, Tuple{Union{Dispatch.Exact,Dispatch.Numerical}}
        ),
    ) !== :clean
end

@testset "an abstract-typed call site that could reach a mark is not clean" begin
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind})
    ) !== :clean
end

@testset "the unresolvable call site is named, not just counted" begin
    # Structured fields, not `occursin`: a short needle matches any boilerplate diagnostic.
    @test all(
        u -> hasproperty(u, :file) && hasproperty(u, :line) && hasproperty(u, :callee),
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind}).unresolved,
    )
    @test any(
        u -> u.callee === :k,
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind}).unresolved,
    )
end

@testset "which() throwing must not be swallowed into :clean" begin
    # The mistake this file exists to prevent: catching `which`, skipping the site, reporting
    # the rest as clean.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_abstract, Tuple{Dispatch.Kind})
    ) === :unknown
end

# ── dispatch subtleties ──────────────────────────────────────────────────────────────────────

@testset "invoke pins the method it names" begin
    # Argument types alone cannot see `invoke` pinning a method dispatch would not pick: an `Int`
    # goes to the unmarked `::Int` method, and only `invoke` reaches the marked `::Integer` one.
    # The entry signature is `Tuple{Int}` because that is the only method `via_invoke` has —
    # the spec was written with `Tuple{Numerical}`, which no method of it matches.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_invoke, Tuple{Int})
    ) === :depends
    # Control: the same argument reaching the same generic WITHOUT `invoke` is clean, so the
    # verdict above is `invoke` being followed and not the argument type being widened.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.more_specific, Tuple{Int})
    ) === :clean
end

@testset "a more specific unmarked method shadows a marked one" begin
    # An `Int` never reaches the mark. `:depends` here is the name-level over-claim one level
    # down.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.more_specific, Tuple{Int})
    ) === :clean
    # …and the call that does fall through is reported.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.more_specific, Tuple{UInt8})
    ) === :depends
end

@testset "a mark on one method does not leak to its siblings at a call site" begin
    # Both call the same name and must get different verdicts.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.only_settled, Tuple{Dispatch.Exact})
    ) !== ExperimentalAPI.verdict(
        ExperimentalAPI.reach(
            Dispatch.either_way, Tuple{Union{Dispatch.Exact,Dispatch.Numerical}}
        ),
    )
end

@testset "a marked combination is not reachable from either argument alone" begin
    # Widening each argument independently would call both call sites `:depends`.
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(Dispatch.via_pair_clean, Tuple{Dispatch.Exact,Dispatch.Exact})
    ) === :clean
    @test ExperimentalAPI.verdict(
        ExperimentalAPI.reach(
            Dispatch.via_pair_marked, Tuple{Dispatch.Numerical,Dispatch.Numerical}
        ),
    ) === :depends
end

@testset "the report says WHICH method was reached, not which name" begin
    @test first(
        ExperimentalAPI.reach(Dispatch.either_way, Tuple{Dispatch.Numerical}).reached
    ).method === which(Dispatch.energy, Tuple{Dispatch.Numerical})
end
